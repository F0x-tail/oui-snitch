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

// ---------------------------------------------------------------------------
// Rogue-AP behaviour, watched across beacons rather than matched per frame.
//
//   Evil twin  one SSID beaconing from a second BSSID whose OUI differs. A
//              second radio for the same network name is either a legitimate
//              extender (same vendor OUI, so not flagged) or an impersonator.
//   KARMA      one BSSID beaconing many different SSIDs, the signature of a
//              Pineapple-style AP answering whatever clients ask for.
//
// Fixed tables, no allocation: this runs in the promiscuous callback.
struct SsidOwner {
    uint32_t ssidHash;
    uint8_t  bssid[6];
    uint32_t lastMs;
    bool     alerted;
};
struct BssidNames {
    uint8_t  bssid[6];
    uint32_t hashes[8];
    uint8_t  n;
    uint32_t lastMs;
    bool     alerted;
};
static SsidOwner  ssidOwners[24];
static BssidNames bssidNames[8];
static const uint32_t AP_STALE_MS      = 300000;  // forget after 5 min
static const uint8_t  KARMA_SSID_COUNT = 5;       // distinct SSIDs from one BSSID

static inline uint32_t IRAM_ATTR ssidHash32(const uint8_t* s, int n) {
    uint32_t h = 2166136261u;                     // FNV-1a
    for (int i = 0; i < n; i++) { h ^= s[i]; h *= 16777619u; }
    return h ? h : 1u;                            // 0 marks an empty slot
}

// Pull the SSID element out of a beacon/probe-response body. Returns length.
static inline int IRAM_ATTR beaconSsid(const uint8_t* p, int len, const uint8_t** out) {
    int off = 36;                                 // after the fixed parameters
    while (off + 2 <= len) {
        uint8_t id = p[off], elen = p[off + 1];
        if (off + 2 + elen > len) break;
        if (id == 0) { *out = &p[off + 2]; return elen; }
        off += 2 + elen;
    }
    return -1;
}

static const uint8_t AXON_OUI[3] = {0x00, 0x25, 0xdf};

// Law-enforcement / public-safety vendors, from the IEEE MA-L registry.
// Axon only ships duty equipment, so its OUI is meaningful on its own. The
// others are not: a Motorola Solutions block covers police radios but also a
// great deal else, so a bare OUI from these is reported as SUSPECTED and only
// an Axon-specific manufacturer ID or service UUID raises the tier.
// `kind` is optional: rows that omit it read "Law Enforcement". It exists so a
// vendor that is not exclusively duty equipment can be described honestly
// instead of being asserted to be police gear.
struct LeVendorOui { uint8_t b[3]; const char* vendor; const char* kind; };
static const LeVendorOui LE_VENDOR_OUIS[] = {
    {{0x00,0x00,0xc3}, "Harris"},
    {{0x00,0x04,0x7d}, "Motorola"},
    {{0x00,0x06,0xec}, "Harris"},
    {{0x00,0x0d,0x4f}, "Kenwood"},
    {{0x00,0x0d,0xca}, "Tait"},
    {{0x00,0x17,0xf3}, "Harris"},
    {{0x00,0x18,0x85}, "Motorola"},
    {{0x00,0x1d,0x96}, "WatchGuard"},
    {{0x00,0x1f,0x92}, "Motorola"},
    {{0x00,0x23,0xbd}, "Digital Ally"},
    {{0x00,0x25,0xdf}, "Axon"},
    {{0x10,0x74,0x6f}, "Motorola"},
    // Skydio, deliberately listed in BOTH categories: a DFR airframe is duty
    // equipment here, and a drone to the Sky Spy engine. Stays SUSPECTED like
    // the radio vendors, since Skydio also sells to enterprise. Remote ID via
    // Sky Spy remains the authoritative identifier.
    {{0x38,0x1d,0x14}, "Skydio", "public-safety drone"},
    {{0x4c,0xcc,0x34}, "Motorola"},
    {{0x64,0x69,0xbc}, "Hytera"},
    {{0x9c,0x06,0x6e}, "Hytera"},
    {{0x9c,0x86,0x2b}, "Motorola"},
    {{0xb8,0xe2,0x8c}, "Motorola"},
    {{0xe0,0xda,0xdc}, "Kenwood"},
};
static const int LE_VENDOR_OUI_COUNT =
    sizeof(LE_VENDOR_OUIS) / sizeof(LE_VENDOR_OUIS[0]);

static const char* leKindLookup(const uint8_t* mac) {
    if (mac[0] & 0x02) return nullptr;
    for (int i = 0; i < LE_VENDOR_OUI_COUNT; i++) {
        if (memcmp(mac, LE_VENDOR_OUIS[i].b, 3) == 0) return LE_VENDOR_OUIS[i].kind;
    }
    return nullptr;
}

static const char* leVendorLookup(const uint8_t* mac) {
    if (mac[0] & 0x02) return nullptr;      // locally administered / random
    for (int i = 0; i < LE_VENDOR_OUI_COUNT; i++) {
        if (memcmp(mac, LE_VENDOR_OUIS[i].b, 3) == 0) return LE_VENDOR_OUIS[i].vendor;
    }
    return nullptr;
}

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
        // Apple packs Continuity as a chain of TLVs after the company ID:
        //   4C 00 <type> <len> <payload...> [<type> <len> <payload...> ...]
        // This used to look only at the FIRST TLV (md[2]/md[3]), so a Find My
        // "separated" record sitting behind another TLV was missed. Observed in
        // the field: a 25-byte blob whose first TLV was the 2-byte nearby
        // record. Walk the chain instead of assuming an offset.
        //
        // Only type 0x12 with length 0x19 counts — that is the separated /
        // offline-finding payload, i.e. a tracker away from its owner. The
        // 2-byte "nearby" variant means the owner is present, which every
        // iPhone and AirPods in range emits and is not a stalking signal.
        if (md.size() >= 4 && (uint8_t)md[0] == 0x4C && (uint8_t)md[1] == 0x00) {
            size_t i = 2;
            while (i + 1 < md.size()) {
                uint8_t ttype = (uint8_t)md[i];
                uint8_t tlen  = (uint8_t)md[i + 1];
                if (i + 2 + tlen > md.size()) break;      // truncated / malformed
                if (ttype == 0x12 && tlen == 0x19) {
                    if (sigMask & SIG_TRACKER) {
                        trackerObserve(mac, rssi, TRK_FAM_APPLE);
                    }
                    return;
                }
                i += 2 + tlen;
            }
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
    if (sigMask & SIG_HACKTOOLS) {
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
        const char* leVendor = leVendorLookup(mac);
        uint8_t tier = DET_CONF_NONE;
        if ((axonMfg || axonSvc) && axonMac)   tier = DET_CONF_VERIFIED;
        else if (axonMfg || axonSvc || axonMac) tier = DET_CONF_HIGH;
        else if (leVendor)                      tier = DET_CONF_SUSPECTED;
        if (tier != DET_CONF_NONE && !sigDedup.check(mac)) {
            const char* vendor = axonMac ? "Axon" : (leVendor ? leVendor : "Axon");
            const char* leKind = axonMac ? nullptr : leKindLookup(mac);
            if (!leKind || !leKind[0]) leKind = "Law Enforcement";
            DetectionEvent evt = {};
            evt.engine_id = ENGINE_DETECTOR;
            memcpy(evt.mac, mac, 6);
            evt.rssi = rssi;
            evt.timestamp_ms = millis();
            evt.method = METHOD_DET_AXON;
            evt.ext.detector.confidence = tier;
            snprintf(evt.ext.detector.filter_desc,
                     sizeof(evt.ext.detector.filter_desc), "%s (%s)", vendor, leKind);
            pushDetection(&evt);
            Serial.printf("[DETECTOR] SIG %02x:%02x:%02x:%02x:%02x:%02x RSSI:%d [%s LE]\n",
                          mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi, vendor);
        }
    }
    if (sigMask & SIG_MESH) {
        // Meshtastic advertises its own 128-bit service UUID, which identifies
        // it outright. MeshCore rides the generic Nordic UART service, which
        // thousands of unrelated devices also use, so it is matched by name and
        // reported a tier lower.
        static const char* MESHTASTIC_SVC = "6ba1b218-15a8-461f-9fa8-5dcae273eafd";
        bool meshtasticSvc = dev->isAdvertisingService(NimBLEUUID(MESHTASTIC_SVC));
        const char* meshKind = nullptr;
        uint8_t meshTier = DET_CONF_NONE;
        if (meshtasticSvc) { meshKind = "Meshtastic"; meshTier = DET_CONF_VERIFIED; }
        if (!meshKind && dev->haveName()) {
            std::string nm = dev->getName();
            if (strcasestr(nm.c_str(), "meshtastic")) {
                meshKind = "Meshtastic"; meshTier = DET_CONF_HIGH;
            } else if (strcasestr(nm.c_str(), "meshcore")) {
                meshKind = "MeshCore";   meshTier = DET_CONF_HIGH;
            }
        }
        if (meshKind && !sigDedup.check(mac)) {
            DetectionEvent evt = {};
            evt.engine_id = ENGINE_DETECTOR;
            memcpy(evt.mac, mac, 6);
            evt.rssi = rssi;
            evt.timestamp_ms = millis();
            evt.method = METHOD_DET_MESH;
            evt.ext.detector.confidence = meshTier;
            snprintf(evt.ext.detector.filter_desc,
                     sizeof(evt.ext.detector.filter_desc), "%s mesh node", meshKind);
            pushDetection(&evt);
            Serial.printf("[DETECTOR] SIG %02x:%02x:%02x:%02x:%02x:%02x RSSI:%d [%s]\n",
                          mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi, meshKind);
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
            // Vendor first: the brand is what identifies the device at a
            // glance, so it leads the notification title.
            snprintf(evt.ext.detector.filter_desc,
                     sizeof(evt.ext.detector.filter_desc), "%s camera",
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

// Watches beacons for the two rogue-AP behaviours above. Returns true when it
// raised a detection.
static bool IRAM_ATTR apObserveISR(const uint8_t* p, int len, int rssi, uint8_t channel) {
    const uint8_t* ssid = nullptr;
    int slen = beaconSsid(p, len, &ssid);
    if (slen <= 0 || slen > 32) return false;     // hidden or malformed
    const uint8_t* bssid = &p[16];                // addr3
    uint32_t h = ssidHash32(ssid, slen);
    uint32_t now = millis();

    // --- evil twin: same SSID, different BSSID, different vendor ---
    int freeSlot = -1;
    for (int i = 0; i < (int)(sizeof(ssidOwners) / sizeof(ssidOwners[0])); i++) {
        SsidOwner& o = ssidOwners[i];
        if (o.ssidHash == 0 || now - o.lastMs > AP_STALE_MS) {
            if (o.ssidHash != 0) o.ssidHash = 0;
            if (freeSlot < 0) freeSlot = i;
            continue;
        }
        if (o.ssidHash != h) continue;
        if (memcmp(o.bssid, bssid, 6) == 0) { o.lastMs = now; return false; }
        // Same name from another radio. A legitimate extender normally shares
        // the vendor OUI, so only a differing OUI is treated as impersonation.
        if (memcmp(o.bssid, bssid, 3) != 0 && !o.alerted) {
            o.alerted = true;
            DetectionEvent evt = {};
            evt.engine_id = ENGINE_DETECTOR;
            memcpy(evt.mac, bssid, 6);
            evt.rssi = rssi;
            evt.channel = channel;
            evt.timestamp_ms = now;
            evt.method = METHOD_DET_EVILTWIN;
            evt.ext.detector.confidence = DET_CONF_HIGH;
            strncpy(evt.ext.detector.filter_desc, "Evil twin (SSID from 2nd BSSID)",
                    sizeof(evt.ext.detector.filter_desc) - 1);
            pushDetectionFromISR(&evt);
            return true;
        }
        return false;
    }
    if (freeSlot >= 0) {
        SsidOwner& o = ssidOwners[freeSlot];
        o.ssidHash = h;
        memcpy(o.bssid, bssid, 6);
        o.lastMs = now;
        o.alerted = false;
    }

    // --- KARMA: one BSSID handing out many different SSIDs ---
    int bFree = -1;
    for (int i = 0; i < (int)(sizeof(bssidNames) / sizeof(bssidNames[0])); i++) {
        BssidNames& b = bssidNames[i];
        if (b.n == 0 || now - b.lastMs > AP_STALE_MS) {
            if (b.n != 0) b.n = 0;
            if (bFree < 0) bFree = i;
            continue;
        }
        if (memcmp(b.bssid, bssid, 6) != 0) continue;
        b.lastMs = now;
        for (int k = 0; k < b.n; k++) if (b.hashes[k] == h) return false;
        if (b.n < 8) b.hashes[b.n++] = h;
        if (b.n >= KARMA_SSID_COUNT && !b.alerted) {
            b.alerted = true;
            DetectionEvent evt = {};
            evt.engine_id = ENGINE_DETECTOR;
            memcpy(evt.mac, bssid, 6);
            evt.rssi = rssi;
            evt.channel = channel;
            evt.timestamp_ms = now;
            evt.method = METHOD_DET_PINEAPPLE;
            evt.ext.detector.confidence = DET_CONF_HIGH;
            strncpy(evt.ext.detector.filter_desc, "KARMA AP (many SSIDs, 1 BSSID)",
                    sizeof(evt.ext.detector.filter_desc) - 1);
            pushDetectionFromISR(&evt);
            return true;
        }
        return false;
    }
    if (bFree >= 0) {
        BssidNames& b = bssidNames[bFree];
        memcpy(b.bssid, bssid, 6);
        b.hashes[0] = h;
        b.n = 1;
        b.lastMs = now;
        b.alerted = false;
    }
    return false;
}

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
                    // Probe SSIDs are attacker-controlled; copy only printable
                    // ASCII into the description that reaches the notification
                    // title and the database. Non-printable bytes become '.'.
                    uint8_t n = ssidLen < 31 ? ssidLen : 31;
                    for (uint8_t k = 0; k < n; k++) {
                        uint8_t c = p[26 + k];
                        evt.ext.detector.filter_desc[k] =
                            (c >= 0x20 && c < 0x7f) ? (char)c : '.';
                    }
                    evt.ext.detector.filter_desc[n] = 0;
                    pushDetectionFromISR(&evt);
                }
            }
        }
        return true;
    }

    static const uint8_t pwnMac[6] = {0xde, 0xad, 0xbe, 0xef, 0xde, 0xad};
    if ((sigMask & SIG_HACKTOOLS) && fctl == 0x80 && memcmp(&p[10], pwnMac, 6) == 0) {
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
        bool axonMac = (memcmp(src, AXON_OUI, 3) == 0);
        const char* leVendor = axonMac ? "Axon" : leVendorLookup(src);
        if (leVendor) {
            if (!axonDedupISR.check(src)) {
                DetectionEvent evt = {};
                evt.engine_id = ENGINE_DETECTOR;
                memcpy(evt.mac, src, 6);
                evt.rssi = rssi;
                evt.channel = channel;
                evt.timestamp_ms = millis();
                evt.method = METHOD_DET_AXON;
                // Axon only ships duty gear; the other vendors make much else.
                evt.ext.detector.confidence = axonMac ? DET_CONF_HIGH : DET_CONF_SUSPECTED;
                strncpy(evt.ext.detector.filter_desc, leVendor,
                        sizeof(evt.ext.detector.filter_desc) - 1);
                pushDetectionFromISR(&evt);
            }
            return true;
        }
    }

    // Beacons also feed the rogue-AP behaviour watch (evil twin / KARMA).
    if ((sigMask & SIG_PROBE) && fctl == 0x80 && len >= 38) {
        if (apObserveISR(p, len, rssi, channel)) return true;
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
            snprintf(evt.ext.detector.filter_desc,
                     sizeof(evt.ext.detector.filter_desc), "%s camera", camVendor);
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
    const uint8_t wifiBits = SIG_DEAUTH | SIG_PROBE | SIG_HACKTOOLS | SIG_AXON | SIG_CAMERA;
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
           (sigMask & (SIG_DEAUTH | SIG_PROBE | SIG_HACKTOOLS | SIG_AXON | SIG_CAMERA)) != 0;
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
                    (sigMask & (SIG_DEAUTH | SIG_PROBE | SIG_HACKTOOLS | SIG_AXON | SIG_CAMERA)) != 0;

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
            (sigMask & (SIG_DEAUTH | SIG_PROBE | SIG_HACKTOOLS | SIG_AXON | SIG_CAMERA))) {
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
