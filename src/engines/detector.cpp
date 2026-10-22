#include "detector.h"
#include "protocol.h"
#include "../mesh_espnow.h"
#include "../radio_coex.h"
#include "../ble_coex.h"
#include "dedup_ring.h"
#include <Arduino.h>
#include <NimBLEDevice.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include "camera_match.h"

// Extended camera OUI entries (reserved for observed Wi-Fi module OUIs) stay off
// unless explicitly enabled; see camera_oui.h.
volatile bool g_cameraExtendedOui = false;

struct TargetFilter {
    uint8_t macBytes[6];
    uint8_t prefixLen;
    char desc[32];
};

struct UuidFilter {
    uint16_t uuid;
    NimBLEUUID nim;
    char desc[32];
};

static TargetFilter filters[50];
static int filterCount = 0;
static UuidFilter uuidFilters[50];
static int uuidFilterCount = 0;
static NimBLEScan* bleScan = nullptr;
static volatile bool scanning = false;
static unsigned long lastScanStart = 0;
static const unsigned long SCAN_INTERVAL_MS = 3000;
static const int SCAN_DURATION_S = 2;

static volatile bool wifiActive = false;
static uint8_t detectorRadioMask = 0x03;
#ifdef OUISPY_DUAL_BAND
static const uint8_t channels[] = {
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    36, 40, 44, 48, 149, 153, 157, 161, 165
};
#else
static const uint8_t channels[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14};
#endif
static const int channelCount = sizeof(channels) / sizeof(channels[0]);
static int channelIdx = 0;
static unsigned long lastChannelHop = 0;
static const unsigned long DWELL_MS = 120;

static DedupRing<32, 3000> dedup;
static DedupRingISR<32, 3000> wifiDedupISR;
static DedupRing<32, 10000> sigDedup;
static DedupRingISR<32, 8000> probeDedup;
static DedupRingISR<16, 8000> axonDedupISR;

static DedupRingISR<16, 8000> cameraDedupISR;

static const uint8_t AXON_OUI[3] = {0x00, 0x25, 0xdf};

static volatile unsigned long deauthWindowStart = 0;
static volatile uint16_t deauthCount = 0;
static volatile unsigned long lastDeauthAlert = 0;
static const uint16_t DEAUTH_THRESHOLD = 10;
static const unsigned long DEAUTH_ALERT_COOLDOWN_MS = 10000;
static volatile unsigned long lastPwnAlert = 0;
static uint8_t sigMask = 0;

static void detectorStart(void);
static void detectorStop(void);

static const TargetFilter* matchFilterBytes(const uint8_t* mac) {
    for (int i = 0; i < filterCount; i++) {
        if (memcmp(mac, filters[i].macBytes, filters[i].prefixLen) == 0) {
            return &filters[i];
        }
    }
    return nullptr;
}

static const UuidFilter* matchUuidFilter(NimBLEAdvertisedDevice* dev) {
    if (uuidFilterCount == 0) return nullptr;
    if (!dev->haveServiceUUID()) return nullptr;
    int n = dev->getServiceUUIDCount();
    for (int i = 0; i < n; i++) {
        NimBLEUUID u = dev->getServiceUUID(i);
        for (int j = 0; j < uuidFilterCount; j++) {
            if (u.equals(uuidFilters[j].nim)) return &uuidFilters[j];
        }
    }
    return nullptr;
}

// ---------------------------------------------------------------------------
// Tracker follow-detection.
//
// Presence is not following. A tag seen for a few seconds is simply nearby --
// a shop shelf, a passer-by, your own keys. What matters is a tag that stays
// with you: present for a long stretch, or leaving and returning repeatedly.
// Each tag is tracked and escalated through three tiers, alerting once per tier
// so a tag that becomes suspicious upgrades rather than repeating:
//
//   SUSPECTED  seen briefly              -- "nearby", informational
//   HIGH       with you for TRK_FOLLOW_MS -- "following"
//   VERIFIED   gone and returned over TRK_WINDOWS_VERIFIED separate windows
//
// Limitation: these tags rotate their MAC (Apple's roughly every 15 minutes
// when away from its owner), so a single MAC cannot be followed indefinitely.
// The thresholds are therefore set inside a typical rotation window, and the
// window counter is what catches a tag that keeps coming back.
enum TrackerFamily : uint8_t {
    TRK_FAM_APPLE = 0,   // Apple Find My
    TRK_FAM_SAMSUNG,     // Samsung SmartTag
    TRK_FAM_TILE,        // Tile
    TRK_FAM_GOOGLE,      // Google Find My Device network
};
static const char* const TRK_FAMILY_NAME[] = {"Find My", "SmartTag", "Tile", "Google FMD"};

struct TrackerTrack {
    uint8_t  mac[6];
    uint32_t firstMs;      // first sighting in this track
    uint32_t lastMs;       // most recent sighting
    uint16_t hits;
    uint8_t  windows;      // separate appearances (absence > TRK_WINDOW_GAP_MS)
    uint8_t  family;
    uint8_t  alerted;      // highest DET_CONF_* already reported
};
static TrackerTrack trkTracks[24];
static const uint16_t TRK_MIN_HITS         = 3;
static const uint32_t TRK_NEAR_MS          = 3000;    // brief presence
static const uint32_t TRK_FOLLOW_MS        = 300000;  // 5 min with you
static const uint32_t TRK_WINDOW_GAP_MS    = 60000;   // absence that ends a window
static const uint8_t  TRK_WINDOWS_VERIFIED = 3;       // left and came back this often
static const uint32_t TRK_SPAN_VERIFIED_MS = 600000;  // ...across at least 10 min
static const uint32_t TRK_STALE_MS         = 1800000; // forget after 30 min unseen

static void trackerObserve(const uint8_t* mac, int rssi, TrackerFamily fam) {
    uint32_t now = millis();
    int slot = -1, freeSlot = -1, oldest = -1;
    uint32_t oldestMs = 0xFFFFFFFF;
    const int n = (int)(sizeof(trkTracks) / sizeof(trkTracks[0]));
    for (int i = 0; i < n; i++) {
        if (trkTracks[i].hits == 0) { if (freeSlot < 0) freeSlot = i; continue; }
        if (now - trkTracks[i].lastMs > TRK_STALE_MS) {
            trkTracks[i].hits = 0;
            if (freeSlot < 0) freeSlot = i;
            continue;
        }
        if (memcmp(trkTracks[i].mac, mac, 6) == 0) { slot = i; break; }
        if (trkTracks[i].lastMs < oldestMs) { oldestMs = trkTracks[i].lastMs; oldest = i; }
    }
    if (slot < 0) {
        slot = (freeSlot >= 0) ? freeSlot : oldest;
        if (slot < 0) return;
        memcpy(trkTracks[slot].mac, mac, 6);
        trkTracks[slot].firstMs = now;
        trkTracks[slot].hits    = 0;
        trkTracks[slot].windows = 1;
        trkTracks[slot].alerted = DET_CONF_NONE;
    } else if (now - trkTracks[slot].lastMs > TRK_WINDOW_GAP_MS) {
        // Was away and is back: a new appearance window.
        if (trkTracks[slot].windows < 0xFF) trkTracks[slot].windows++;
    }
    trkTracks[slot].family = (uint8_t)fam;
    trkTracks[slot].lastMs = now;
    if (trkTracks[slot].hits < 0xFFFF) trkTracks[slot].hits++;
    if (trkTracks[slot].hits < TRK_MIN_HITS) return;

    uint32_t span = now - trkTracks[slot].firstMs;
    uint8_t  tier = DET_CONF_NONE;
    if (trkTracks[slot].windows >= TRK_WINDOWS_VERIFIED && span >= TRK_SPAN_VERIFIED_MS) {
        tier = DET_CONF_VERIFIED;
    } else if (span >= TRK_FOLLOW_MS) {
        tier = DET_CONF_HIGH;
    } else if (span >= TRK_NEAR_MS) {
        tier = DET_CONF_SUSPECTED;
    }
    if (tier == DET_CONF_NONE || tier <= trkTracks[slot].alerted) return;
    trkTracks[slot].alerted = tier;

    const char* famName = TRK_FAMILY_NAME[fam <= TRK_FAM_GOOGLE ? fam : 0];
    DetectionEvent evt = {};
    evt.engine_id = ENGINE_DETECTOR;
    memcpy(evt.mac, mac, 6);
    evt.rssi = rssi;
    evt.timestamp_ms = now;
    evt.method = METHOD_DET_TRACKER;
    evt.ext.detector.confidence = tier;
    if (tier == DET_CONF_VERIFIED) {
        snprintf(evt.ext.detector.filter_desc, sizeof(evt.ext.detector.filter_desc),
                 "%s returned %ux/%lum", famName, trkTracks[slot].windows,
                 (unsigned long)(span / 60000));
    } else if (tier == DET_CONF_HIGH) {
        snprintf(evt.ext.detector.filter_desc, sizeof(evt.ext.detector.filter_desc),
                 "%s following %lum", famName, (unsigned long)(span / 60000));
    } else {
        snprintf(evt.ext.detector.filter_desc, sizeof(evt.ext.detector.filter_desc),
                 "%s nearby", famName);
    }
    pushDetection(&evt);
    Serial.printf("[DETECTOR] TRACKER %02x:%02x:%02x:%02x:%02x:%02x %s %s (%lus, %u windows)\n",
                  mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], famName,
                  tier == DET_CONF_VERIFIED ? "RETURNING" :
                  tier == DET_CONF_HIGH ? "FOLLOWING" : "nearby",
                  (unsigned long)(span / 1000), trkTracks[slot].windows);
}

static void detectorCheckSignatures(NimBLEAdvertisedDevice* dev, const uint8_t* mac, int rssi) {
#ifdef OUISPY_SIG_DEBUG
    {
        std::string dbgName = dev->getName();
        Serial.printf("[SIG-DBG] %02x:%02x:%02x:%02x:%02x:%02x rssi=%d name='%s'",
                      mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi,
                      dbgName.c_str());
        if (dev->haveManufacturerData()) {
            std::string dm = dev->getManufacturerData();
            if (dm.size() >= 2) {
                Serial.printf(" cid=0x%04X mlen=%u",
                              (unsigned)((uint8_t)dm[0] | ((uint8_t)dm[1] << 8)),
                              (unsigned)dm.size());
            }
        }
        if (dev->haveServiceUUID()) {
            int un = dev->getServiceUUIDCount();
            for (int i = 0; i < un; i++) {
                Serial.printf(" svc=%s", dev->getServiceUUID(i).toString().c_str());
            }
        }
        Serial.printf(" sig=0x%02X\n", sigMask);
    }
#endif
    if (dev->haveManufacturerData()) {
        std::string md = dev->getManufacturerData();
#ifdef OUISPY_FM_DEBUG
        if (md.size() >= 4 && (uint8_t)md[0] == 0x4C && (uint8_t)md[1] == 0x00 &&
            ((uint8_t)md[2] == 0x12 || (uint8_t)md[2] == 0x07)) {
            Serial.printf("[FM-DBG] %02x:%02x:%02x:%02x:%02x:%02x type=0x%02x len=0x%02x size=%u rssi=%d sig=0x%02x\n",
                mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
                (uint8_t)md[2], (uint8_t)md[3], (unsigned)md.size(), rssi, sigMask);
        }
#endif
        if (md.size() >= 24 && (uint8_t)md[0] == 0x4C && (uint8_t)md[1] == 0x00 &&
            (uint8_t)md[2] == 0x12 && (uint8_t)md[3] == 0x19) {
            if (sigMask & SIG_TRACKER) trackerObserve(mac, rssi, TRK_FAM_APPLE);
            return;
        }
    }
    if (sigMask & SIG_TRACKER) {
        // Samsung SmartTag / SmartTag+ and Tile both advertise a fixed 16-bit
        // service UUID, so the UUID alone identifies the family.
        if (dev->isAdvertisingService(NimBLEUUID((uint16_t)0xFD5A))) {
            trackerObserve(mac, rssi, TRK_FAM_SAMSUNG);
            return;
        }
        if (dev->isAdvertisingService(NimBLEUUID((uint16_t)0xFEED))) {
            trackerObserve(mac, rssi, TRK_FAM_TILE);
            return;
        }
        // Google's Find My Device network rides the Eddystone UUID (0xFEAA), so
        // the UUID on its own would also match ordinary Eddystone beacons. The
        // FMDN frame is distinguished by its 0x40 frame type.
        if (dev->isAdvertisingService(NimBLEUUID((uint16_t)0xFEAA))) {
            std::string sd = dev->getServiceData(NimBLEUUID((uint16_t)0xFEAA));
            if (sd.size() >= 1 && (uint8_t)sd[0] == 0x40) {
                trackerObserve(mac, rssi, TRK_FAM_GOOGLE);
                return;
            }
        }
    }
    if (sigMask & SIG_FLIPPER) {
        bool flip = dev->isAdvertisingService(NimBLEUUID((uint16_t)0x3081)) ||
                    dev->isAdvertisingService(NimBLEUUID((uint16_t)0x3082)) ||
                    dev->isAdvertisingService(NimBLEUUID((uint16_t)0x3083));
        if (flip && !sigDedup.check(mac)) {
            DetectionEvent evt = {};
            evt.engine_id = ENGINE_DETECTOR;
            memcpy(evt.mac, mac, 6);
            evt.rssi = rssi;
            evt.timestamp_ms = millis();
            evt.method = METHOD_DET_FLIPPER;
            strncpy(evt.ext.detector.filter_desc, "Flipper Zero",
                    sizeof(evt.ext.detector.filter_desc) - 1);
            pushDetection(&evt);
            Serial.printf("[DETECTOR] SIG %02x:%02x:%02x:%02x:%02x:%02x RSSI:%d [Flipper Zero]\n",
                          mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi);
        }
    }
    if (sigMask & SIG_GLASSES) {
        bool metaMfg = false;
        if (dev->haveManufacturerData()) {
            std::string gm = dev->getManufacturerData();
            if (gm.size() >= 2) {
                uint16_t cid = (uint16_t)((uint8_t)gm[0] | ((uint8_t)gm[1] << 8));
                metaMfg = (cid == 0x0D53);
            }
        }
        bool metaSvc = dev->isAdvertisingService(NimBLEUUID((uint16_t)0xFD5F));
        bool metaName = false;
        if (dev->haveName()) {
            std::string nm = dev->getName();
            metaName = nm.find("Ray-Ban") != std::string::npos ||
                       nm.find("Wayfarer") != std::string::npos ||
                       nm.find("Oakley Meta") != std::string::npos;
        }
        static const uint8_t META_OUIS[][3] = {
            {0x98, 0x59, 0x49}, {0x80, 0xAA, 0x1C}, {0x38, 0x47, 0x12}};
        bool metaMac = false;
        for (const auto& oui : META_OUIS) {
            if (memcmp(mac, oui, 3) == 0) { metaMac = true; break; }
        }
        if ((metaMfg || metaSvc || metaName || metaMac) && !sigDedup.check(mac)) {
            DetectionEvent evt = {};
            evt.engine_id = ENGINE_DETECTOR;
            memcpy(evt.mac, mac, 6);
            evt.rssi = rssi;
            evt.timestamp_ms = millis();
            evt.method = METHOD_DET_GLASSES;
            strncpy(evt.ext.detector.filter_desc, "Meta smart glasses",
                    sizeof(evt.ext.detector.filter_desc) - 1);
            pushDetection(&evt);
            Serial.printf("[DETECTOR] SIG %02x:%02x:%02x:%02x:%02x:%02x RSSI:%d [Meta glasses]\n",
                          mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi);
        }
    }
    if (sigMask & SIG_AXON) {
        bool axonMfg = false;
        if (dev->haveManufacturerData()) {
            std::string am = dev->getManufacturerData();
            if (am.size() >= 2) {
                uint16_t cid = (uint16_t)((uint8_t)am[0] | ((uint8_t)am[1] << 8));
                axonMfg = (cid == 0x034D);
            }
        }
        bool axonSvc = dev->isAdvertisingService(NimBLEUUID((uint16_t)0xFC81)) ||
                       dev->isAdvertisingService(NimBLEUUID((uint16_t)0xFE6B)) ||
                       dev->isAdvertisingService(NimBLEUUID((uint16_t)0xFE6C));
        bool axonMac = (memcmp(mac, AXON_OUI, 3) == 0);
        if ((axonMac || axonMfg || axonSvc) && !sigDedup.check(mac)) {
            DetectionEvent evt = {};
            evt.engine_id = ENGINE_DETECTOR;
            memcpy(evt.mac, mac, 6);
            evt.rssi = rssi;
            evt.timestamp_ms = millis();
            evt.method = METHOD_DET_AXON;
            strncpy(evt.ext.detector.filter_desc, "Axon (Law Enforcement)",
                    sizeof(evt.ext.detector.filter_desc) - 1);
            pushDetection(&evt);
            Serial.printf("[DETECTOR] SIG %02x:%02x:%02x:%02x:%02x:%02x RSSI:%d [Axon LE]\n",
                          mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi);
        }
    }
    if (sigMask & SIG_CAMERA) {
        const char* camVendor = cameraMatchOui(mac);
        const char* camName   = nullptr;
        if (dev->haveName()) {
            std::string nm = dev->getName();
            // cameraMatchName returns a pointer into the static pattern table,
            // so it stays valid after nm goes out of scope.
            camName = cameraMatchName(nm.c_str());
        }
        CameraConf conf = cameraScore(camVendor, camName);
        if (conf != CAMERA_CONF_NONE && !sigDedup.check(mac)) {
            DetectionEvent evt = {};
            evt.engine_id = ENGINE_DETECTOR;
            memcpy(evt.mac, mac, 6);
            evt.rssi = rssi;
            evt.timestamp_ms = millis();
            evt.method = METHOD_DET_CAMERA;
            evt.ext.detector.confidence = (uint8_t)conf;
            snprintf(evt.ext.detector.filter_desc,
                     sizeof(evt.ext.detector.filter_desc), "Camera (%s)",
                     camVendor ? camVendor : camName);
            pushDetection(&evt);
            Serial.printf("[DETECTOR] SIG %02x:%02x:%02x:%02x:%02x:%02x RSSI:%d [Camera %s %s]\n",
                          mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi,
                          camVendor ? camVendor : "name-match", cameraConfName(conf));
        }
    }
}

class DetectorCallback : public NimBLEAdvertisedDeviceCallbacks {
    void onResult(NimBLEAdvertisedDevice* dev) override {
        g_engRawSeen++;
        if (!scanning) return;
        uint8_t mac[6];
        bleAddrToMac(dev->getAddress().getNative(), mac);
        detectorCheckSignatures(dev, mac, dev->getRSSI());

        const TargetFilter* hit = matchFilterBytes(mac);
        if (!hit) { detectorCheckBleUuid(dev, mac, dev->getRSSI()); return; }
        if (dedup.check(mac)) return;

        DetectionEvent evt = {};
        evt.engine_id = ENGINE_DETECTOR;
        memcpy(evt.mac, mac, 6);
        evt.rssi = dev->getRSSI();
        evt.timestamp_ms = millis();
        evt.ext.detector.is_full_mac = (hit->prefixLen == 6) ? 1 : 0;
        strncpy(evt.ext.detector.filter_desc, hit->desc, sizeof(evt.ext.detector.filter_desc) - 1);
        pushDetection(&evt);

        Serial.printf("[DETECTOR] BLE %02x:%02x:%02x:%02x:%02x:%02x RSSI:%d [%s] %s\n",
                      mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
                      dev->getRSSI(),
                      hit->prefixLen == 6 ? "MAC" : "OUI", hit->desc);
    }
};

static DetectorCallback scanCb;

static bool IRAM_ATTR detectorSigFrameISR(const uint8_t* p, int len, int rssi, uint8_t channel) {
    uint8_t fctl = p[0];
    if ((sigMask & SIG_DEAUTH) && (fctl == 0xC0 || fctl == 0xA0)) {
        unsigned long now = millis();
        if (now - deauthWindowStart > 1000) { deauthWindowStart = now; deauthCount = 0; }
        if (deauthCount < 0xFFFF) deauthCount++;
        if (deauthCount >= DEAUTH_THRESHOLD && now - lastDeauthAlert > DEAUTH_ALERT_COOLDOWN_MS) {
            lastDeauthAlert = now;
            DetectionEvent evt = {};
            evt.engine_id = ENGINE_DETECTOR;
            memcpy(evt.mac, &p[10], 6);
            evt.rssi = rssi;
            evt.channel = channel;
            evt.timestamp_ms = now;
            evt.method = METHOD_DET_DEAUTH;
            strncpy(evt.ext.detector.filter_desc, "Deauth/Disassoc storm",
                    sizeof(evt.ext.detector.filter_desc) - 1);
            pushDetectionFromISR(&evt);
        }
        return true;
    }

    if ((sigMask & SIG_PROBE) && fctl == 0x40) {
        if (len >= 28 && p[24] == 0x00) {
            uint8_t ssidLen = p[25];
            if (ssidLen > 0 && ssidLen <= 32 && 26 + ssidLen <= len) {
                const uint8_t* src = &p[10];
                if (!probeDedup.check(src)) {
                    DetectionEvent evt = {};
                    evt.engine_id = ENGINE_DETECTOR;
                    memcpy(evt.mac, src, 6);
                    evt.rssi = rssi;
                    evt.channel = channel;
                    evt.timestamp_ms = millis();
                    evt.method = METHOD_DET_PROBE;
                    uint8_t n = ssidLen < 31 ? ssidLen : 31;
                    memcpy(evt.ext.detector.filter_desc, &p[26], n);
                    evt.ext.detector.filter_desc[n] = 0;
                    pushDetectionFromISR(&evt);
                }
            }
        }
        return true;
    }

    static const uint8_t pwnMac[6] = {0xde, 0xad, 0xbe, 0xef, 0xde, 0xad};
    if ((sigMask & SIG_PWNAGOTCHI) && fctl == 0x80 && memcmp(&p[10], pwnMac, 6) == 0) {
        unsigned long now = millis();
        if (now - lastPwnAlert > 15000) {
            lastPwnAlert = now;
            DetectionEvent evt = {};
            evt.engine_id = ENGINE_DETECTOR;
            memcpy(evt.mac, &p[10], 6);
            evt.rssi = rssi;
            evt.channel = channel;
            evt.timestamp_ms = now;
            evt.method = METHOD_DET_PWNAGOTCHI;
            strncpy(evt.ext.detector.filter_desc, "Pwnagotchi",
                    sizeof(evt.ext.detector.filter_desc) - 1);
            pushDetectionFromISR(&evt);
        }
        return true;
    }

    if (sigMask & SIG_AXON) {
        const uint8_t* src = &p[10];
        if (memcmp(src, AXON_OUI, 3) == 0) {
            if (!axonDedupISR.check(src)) {
                DetectionEvent evt = {};
                evt.engine_id = ENGINE_DETECTOR;
                memcpy(evt.mac, src, 6);
                evt.rssi = rssi;
                evt.channel = channel;
                evt.timestamp_ms = millis();
                evt.method = METHOD_DET_AXON;
                strncpy(evt.ext.detector.filter_desc, "Axon (Law Enforcement)",
                        sizeof(evt.ext.detector.filter_desc) - 1);
                pushDetectionFromISR(&evt);
            }
            return true;
        }
    }

    if (sigMask & SIG_CAMERA) {
        const uint8_t* src = &p[10];
        const char* camVendor = cameraMatchOuiISR(src);
        if (camVendor && !cameraDedupISR.check(src)) {
            DetectionEvent evt = {};
            evt.engine_id = ENGINE_DETECTOR;
            memcpy(evt.mac, src, 6);
            evt.rssi = rssi;
            evt.channel = channel;
            evt.timestamp_ms = millis();
            evt.method = METHOD_DET_CAMERA;
            // OUI alone: a vendor block covers more than that vendor's cameras.
            evt.ext.detector.confidence = DET_CONF_SUSPECTED;
            strncpy(evt.ext.detector.filter_desc, camVendor,
                    sizeof(evt.ext.detector.filter_desc) - 1);
            pushDetectionFromISR(&evt);
            return true;
        }
    }

    return false;
}

void IRAM_ATTR detectorCheckWifiSignaturesISR(const uint8_t* payload, int len, int rssi,
                                              uint8_t channel) {
    if (!scanning || sigMask == 0 || payload == nullptr || len < 24) return;
    detectorSigFrameISR(payload, len, rssi, channel);
}

static void IRAM_ATTR wifiSnifferCb(void* buf, wifi_promiscuous_pkt_type_t type) {
    g_engRawSeen++;
    if (!scanning || !wifiActive) return;
    if (type != WIFI_PKT_MGMT && type != WIFI_PKT_DATA) return;

    wifi_promiscuous_pkt_t* pkt = (wifi_promiscuous_pkt_t*)buf;
    uint8_t* p = pkt->payload;
    int len = pkt->rx_ctrl.sig_len;
    if (len < 24) return;

    if (detectorSigFrameISR(p, len, pkt->rx_ctrl.rssi, pkt->rx_ctrl.channel)) return;

    const uint8_t* addr2 = &p[10];
    const TargetFilter* hit = matchFilterBytes(addr2);
    if (!hit) return;
    if (wifiDedupISR.check(addr2)) return;

    DetectionEvent evt = {};
    evt.engine_id = ENGINE_DETECTOR;
    memcpy(evt.mac, addr2, 6);
    evt.rssi = pkt->rx_ctrl.rssi;
    evt.channel = pkt->rx_ctrl.channel;
    evt.timestamp_ms = millis();
    evt.method = 1;
    pushDetectionFromISR(&evt);
}

void detectorCheckBleDevice(const uint8_t* mac, int rssi) {
    if (!scanning) return;
    const TargetFilter* hit = matchFilterBytes(mac);
    if (!hit) return;
    if (dedup.check(mac)) return;

    DetectionEvent evt = {};
    evt.engine_id = ENGINE_DETECTOR;
    memcpy(evt.mac, mac, 6);
    evt.rssi = rssi;
    evt.timestamp_ms = millis();
    evt.ext.detector.is_full_mac = (hit->prefixLen == 6) ? 1 : 0;
    strncpy(evt.ext.detector.filter_desc, hit->desc, sizeof(evt.ext.detector.filter_desc) - 1);
    pushDetection(&evt);

    Serial.printf("[DETECTOR] BLE %02x:%02x:%02x:%02x:%02x:%02x RSSI:%d [%s] %s (via wardrive)\n",
                  mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
                  rssi, hit->prefixLen == 6 ? "MAC" : "OUI", hit->desc);
}

void detectorCheckBleSignatures(NimBLEAdvertisedDevice* dev, const uint8_t* mac, int rssi) {
    if (!scanning || sigMask == 0 || dev == nullptr) return;
    detectorCheckSignatures(dev, mac, rssi);
}

void detectorCheckBleUuid(NimBLEAdvertisedDevice* dev, const uint8_t* mac, int rssi) {
    if (!scanning) return;
    const UuidFilter* hit = matchUuidFilter(dev);
    if (!hit) return;
    if (dedup.check(mac)) return;

    DetectionEvent evt = {};
    evt.engine_id = ENGINE_DETECTOR;
    memcpy(evt.mac, mac, 6);
    evt.rssi = rssi;
    evt.timestamp_ms = millis();
    evt.ext.detector.is_full_mac = 0;
    strncpy(evt.ext.detector.filter_desc, hit->desc, sizeof(evt.ext.detector.filter_desc) - 1);
    pushDetection(&evt);

    Serial.printf("[DETECTOR] BLE %02x:%02x:%02x:%02x:%02x:%02x RSSI:%d [UUID:%04X] %s\n",
                  mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
                  rssi, hit->uuid, hit->desc);
}

void IRAM_ATTR detectorCheckWifiDeviceISR(const uint8_t* mac, int rssi, uint8_t channel) {
    if (!scanning) return;
    const TargetFilter* hit = matchFilterBytes(mac);
    if (!hit) return;
    if (wifiDedupISR.check(mac)) return;

    DetectionEvent evt = {};
    evt.engine_id = ENGINE_DETECTOR;
    memcpy(evt.mac, mac, 6);
    evt.rssi = rssi;
    evt.channel = channel;
    evt.timestamp_ms = millis();
    evt.method = 1;
    evt.ext.detector.is_full_mac = (hit->prefixLen == 6) ? 1 : 0;
    strncpy(evt.ext.detector.filter_desc, hit->desc, sizeof(evt.ext.detector.filter_desc) - 1);
    pushDetectionFromISR(&evt);
}

void detectorClearFilters(void) {
    filterCount = 0;
    uuidFilterCount = 0;
    Serial.println("[DETECTOR] Filters cleared");
}

void detectorAddUuidFilter(uint16_t uuid, const char* desc) {
    if (uuidFilterCount >= 50) return;
    UuidFilter f = {};
    f.uuid = uuid;
    f.nim = NimBLEUUID(uuid);
    if (desc) strncpy(f.desc, desc, sizeof(f.desc) - 1);
    uuidFilters[uuidFilterCount++] = f;
    Serial.printf("[DETECTOR] +uuid filter 0x%04X desc=%s (total=%d)\n",
                  uuid, f.desc, uuidFilterCount);
}

void detectorAddFilter(const uint8_t* macBytes, uint8_t prefixLen, const char* desc) {
    if (filterCount >= 50) return;
    if (prefixLen == 0 || prefixLen > 6) return;
    TargetFilter f = {};
    memcpy(f.macBytes, macBytes, 6);
    f.prefixLen = prefixLen;
    if (desc) strncpy(f.desc, desc, sizeof(f.desc) - 1);
    filters[filterCount++] = f;
    Serial.printf("[DETECTOR] +filter %02x:%02x:%02x len=%u desc=%s (total=%d)\n",
                  macBytes[0], macBytes[1], macBytes[2], prefixLen,
                  f.desc, filterCount);
}

int detectorFilterCount(void) { return filterCount; }

const char* detectorLookupDesc(const uint8_t* mac) {
    if (!mac) return "";
    const TargetFilter* f = matchFilterBytes(mac);
    return f ? f->desc : "";
}

size_t detectorSerialize(uint8_t* out, size_t maxLen) {
    if (out == nullptr || maxLen < 1) return 0;
    size_t off = 1;
    uint8_t cnt = 0;
    for (int i = 0; i < filterCount; i++) {
        if (off + 7 > maxLen) break;
        out[off++] = filters[i].prefixLen;
        memcpy(out + off, filters[i].macBytes, 6);
        off += 6;
        cnt++;
    }
    out[0] = cnt;

    if (off + 1 <= maxLen) {
        size_t ucntPos = off++;
        uint8_t ucnt = 0;
        for (int i = 0; i < uuidFilterCount; i++) {
            if (off + 2 > maxLen) break;
            out[off++] = uuidFilters[i].uuid & 0xFF;
            out[off++] = (uuidFilters[i].uuid >> 8) & 0xFF;
            ucnt++;
        }
        out[ucntPos] = ucnt;
    }
    return off;
}

void detectorSetFilters(const uint8_t* data, size_t len) {
    if (data == nullptr || len < 1) return;
    static uint8_t lastFilters[512]; static size_t lastFilterLen = 0; static bool haveFilters = false;
    if (haveFilters && len == lastFilterLen && len <= sizeof(lastFilters) && memcmp(lastFilters, data, len) == 0) return;
    if (len <= sizeof(lastFilters)) { memcpy(lastFilters, data, len); lastFilterLen = len; haveFilters = true; }
    detectorClearFilters();
    uint8_t cnt = data[0];
    size_t off = 1;
    for (uint8_t i = 0; i < cnt; i++) {
        if (off + 7 > len) break;
        uint8_t prefixLen = data[off];
        detectorAddFilter(data + off + 1, prefixLen, "");
        off += 7;
    }
    if (off < len) {
        uint8_t ucnt = data[off++];
        for (uint8_t i = 0; i < ucnt; i++) {
            if (off + 2 > len) break;
            uint16_t uuid = data[off] | (data[off + 1] << 8);
            detectorAddUuidFilter(uuid, "");
            off += 2;
        }
    }
    Serial.printf("[CFG] Detector watchlist: %u mac + %u uuid filters sig=0x%02X\n",
                  detectorFilterCount(), uuidFilterCount, sigMask);
}

void detectorSetSigMask(uint8_t mask) {
    const uint8_t wifiBits = SIG_DEAUTH | SIG_PROBE | SIG_PWNAGOTCHI | SIG_AXON | SIG_CAMERA;
    bool prevWifi = (sigMask & wifiBits) != 0;
    sigMask = mask;
    bool newWifi = (sigMask & wifiBits) != 0;
    if (scanning && prevWifi != newWifi &&
        engineGetState(ENGINE_WARDRIVE) == ESTATE_DISABLED) {
        detectorStop();
        detectorStart();
    }
}
uint8_t detectorGetSigMask(void) { return sigMask; }

bool detectorUsesWifi(void) {
    return (detectorRadioMask & 0x01) != 0 &&
           (sigMask & (SIG_DEAUTH | SIG_PROBE | SIG_PWNAGOTCHI | SIG_AXON | SIG_CAMERA)) != 0;
}

static void detectorInit(void) {
    dedup.reset();
    wifiDedupISR.reset();
    cameraDedupISR.reset();
    // Build the camera OUI buckets here: the ISR lookup never builds them, it
    // just misses until they are ready.
    cameraOuiInitBuckets();
    Serial.printf("[DETECTOR] Initialized (preserved filters=%d)\n", filterCount);
}

static void detectorStart(void) {
    scanning = true;
    dedup.setCooldownMs(engineGetRediscoverMs());
    wifiDedupISR.setCooldownMs(engineGetRediscoverMs());
    bool wardriveOwns = (engineGetState(ENGINE_WARDRIVE) != ESTATE_DISABLED);
    bool wantBle  = (detectorRadioMask & 0x02) != 0;
    bool wantWifi = (detectorRadioMask & 0x01) != 0 &&
                    (sigMask & (SIG_DEAUTH | SIG_PROBE | SIG_PWNAGOTCHI | SIG_AXON | SIG_CAMERA)) != 0;

    if (!wardriveOwns && wantBle) {
        bleScan = NimBLEDevice::getScan();
        bleCoexRegister(&scanCb, true);
        bleScan->setActiveScan(true);
        bleScan->setInterval(100);
        bleScan->setWindow(99);
        lastScanStart = 0;
    }

    if (!wardriveOwns && wantWifi) {
        if (!meshIsEnabled()) {
            WiFi.mode(WIFI_STA);
        }
        wifiSnifferApplyPs();
        wifiApplyRegdomain();
        wifiCoexRegister(wifiSnifferCb, WIFI_PROMIS_FILTER_MASK_MGMT);
        channelIdx = 0;
        while (channelIdx < channelCount - 1 && !wifiChanEnabled(channels[channelIdx])) channelIdx++;
        esp_wifi_set_channel(channels[channelIdx], WIFI_SECOND_CHAN_NONE);
        lastChannelHop = millis();
        wifiActive = true;
    }

    const char* mode = wardriveOwns ? "passive — wardrive feeds"
                     : (wantWifi && wantBle) ? "WiFi+BLE"
                     : wantWifi ? "WiFi only"
                     : wantBle  ? "BLE only" : "no radio";
    Serial.printf("[DETECTOR] Started (%s) filters=%d\n", mode, filterCount);
}

static void detectorConfig(const uint8_t* payload, uint8_t len) {
    if (len < 1) return;
    const char* self = meshGetLocalNodeId();
    if (!cfgTgtStrip(&payload, &len, self)) return;
    if (len < 1) return;
    uint8_t mask = payload[0] & 0x03;
    if (mask == 0) mask = 0x03;
    uint8_t prev = detectorRadioMask;
    detectorRadioMask = mask;
    Serial.printf("[DETECTOR] Config radio mask=0x%02x\n", detectorRadioMask);
    if (scanning && mask != prev) {
        Serial.printf("[DETECTOR] radio 0x%02x->0x%02x while running — restart\n", prev, mask);
        detectorStop();
        detectorStart();
    }
}

static void detectorStop(void) {
    scanning = false;

    if (wifiActive) {
        wifiActive = false;
        wifiCoexUnregister(wifiSnifferCb);
        if (meshIsEnabled() || wifiCoexActive() || wifiRadioExternallyOwned()) {
            WiFi.disconnect(false, false);
            esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE);
        } else {
            WiFi.disconnect(true);
            WiFi.mode(WIFI_OFF);
        }
    }

    bleCoexUnregister(&scanCb);
    bleScan = nullptr;

    Serial.println("[DETECTOR] Stopped");
}

void detectorHostSuspend(bool suspend) {
    if (suspend) {
        wifiCoexUnregister(wifiSnifferCb);
        bleCoexUnregister(&scanCb);
    } else if (scanning) {
        if (detectorRadioMask & 0x02) {
            bleScan = NimBLEDevice::getScan();
            bleCoexRegister(&scanCb, true);
        }
        if ((detectorRadioMask & 0x01) &&
            (sigMask & (SIG_DEAUTH | SIG_PROBE | SIG_PWNAGOTCHI | SIG_AXON | SIG_CAMERA))) {
            if (!meshIsEnabled()) WiFi.mode(WIFI_STA);
            wifiSnifferApplyPs();
            wifiCoexRegister(wifiSnifferCb, WIFI_PROMIS_FILTER_MASK_MGMT);
            wifiActive = true;
        }
    }
}

static void detectorLoop(void) {
    if (meshIsEnabled() && (meshInMeshWindow() || meshInRidWindow())) return;
    if (!scanning) return;
    if (engineGetState(ENGINE_WARDRIVE) != ESTATE_DISABLED) return;

    if (wifiActive && wifiCoexShouldHop(ENGINE_DETECTOR) &&
        millis() - lastChannelHop >= DWELL_MS) {
        int guard = 0;
        do {
            channelIdx = (channelIdx + 1) % channelCount;
        } while (!wifiChanEnabled(channels[channelIdx]) && ++guard < channelCount);
        esp_wifi_set_channel(channels[channelIdx], WIFI_SECOND_CHAN_NONE);
        lastChannelHop = millis();
        if (meshIsEnabled() && channels[channelIdx] == 1) meshNoteOnHome();
    }

    if (detectorRadioMask & 0x02) bleCoexEnsureScanning();
}

static void detectorApplyPrefs(void) {
    dedup.setCooldownMs(engineGetRediscoverMs());
}

const EngineCallbacks detectorCallbacks = {
    .init       = detectorInit,
    .start      = detectorStart,
    .stop       = detectorStop,
    .loop       = detectorLoop,
    .config     = detectorConfig,
    .applyPrefs = detectorApplyPrefs,
    .name       = "Detector"
};
