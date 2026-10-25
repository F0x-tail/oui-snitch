// SPDX-License-Identifier: MIT
#include "axon.h"
#include "axon_match.h"
#include "protocol.h"
#include "../mesh_espnow.h"
#include "../radio_coex.h"
#include "../ble_coex.h"
#include "dedup_ring.h"
#include <Arduino.h>
#include <NimBLEDevice.h>
#include <WiFi.h>
#include <esp_wifi.h>

// Dedicated Axon / TASER duty-equipment engine.
//
// The signature matching is NOT duplicated here: it lives in axon_match.h and
// is shared with the detector's SIG_AXON branch. What this engine adds is a
// tile of its own — independent enable, its own radio slice, and a scan that
// runs whether or not the broad detector is on. A user hunting for body cameras
// should not have to enable every other signature class to do it.
//
// Radio handling follows the detector exactly: when another engine already owns
// the radio (wardrive sweeping, for instance) this engine goes passive and is
// fed frames through axonCheckBleDevice()/axonCheckWifiISR() instead of
// contending for the hardware.

static bool scanning = false;
static bool wifiActive = false;
static NimBLEScan* bleScan = nullptr;
static uint8_t axonRadioMask = 0x03;   // bit0 Wi-Fi, bit1 BLE

static const uint8_t channels[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14};
static const int channelCount = sizeof(channels) / sizeof(channels[0]);
static int channelIdx = 0;
static unsigned long lastChannelHop = 0;
static const unsigned long DWELL_MS = 120;

// Separate dedup state from the detector's: both may report the same device,
// and suppressing one because the other just saw it would make a tile look dead.
static DedupRing<16, 8000>     bleDedup;
static DedupRingISR<16, 8000>  wifiDedupISR;

bool axonIsActive(void) { return scanning; }
bool axonUsesWifi(void) { return scanning && (axonRadioMask & 0x01) != 0; }

static void emit(const uint8_t* mac, int rssi, uint8_t channel, uint8_t tier,
                 const char* what, bool fromIsr) {
    DetectionEvent evt = {};
    evt.engine_id = ENGINE_AXON;
    memcpy(evt.mac, mac, 6);
    evt.rssi = rssi;
    evt.channel = channel;
    evt.timestamp_ms = millis();
    evt.method = METHOD_DET_AXON;
    evt.ext.detector.confidence = tier;
    strncpy(evt.ext.detector.filter_desc, what,
            sizeof(evt.ext.detector.filter_desc) - 1);
    if (fromIsr) pushDetectionFromISR(&evt);
    else         pushDetection(&evt);
}

// ---------------------------------------------------------------------------
// BLE

void axonCheckBleDevice(NimBLEAdvertisedDevice* dev, const uint8_t* mac, int rssi) {
    if (!scanning || !dev || !mac) return;

    bool mfg = false;
    if (dev->haveManufacturerData()) {
        std::string am = dev->getManufacturerData();
        mfg = axonMfgMatches((const uint8_t*)am.data(), am.size());
    }
    bool svc = false;
    for (unsigned u = 0; u < sizeof(AXON_SVC_UUIDS) / sizeof(AXON_SVC_UUIDS[0]); u++) {
        if (dev->isAdvertisingService(NimBLEUUID(AXON_SVC_UUIDS[u]))) { svc = true; break; }
    }
    bool macHit = axonMacMatches(mac);

    uint8_t tier = axonConfidence(mfg || svc, macHit);
    if (tier == AXON_CONF_NONE) return;
    if (bleDedup.check(mac)) return;

    emit(mac, rssi, 0, tier, "Axon (duty equipment)", false);
    Serial.printf("[AXON] BLE %02x:%02x:%02x:%02x:%02x:%02x RSSI:%d tier=%u\n",
                  mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi, tier);
}

class AxonBleCallback : public NimBLEAdvertisedDeviceCallbacks {
    void onResult(NimBLEAdvertisedDevice* dev) override {
        if (!scanning) return;
        uint8_t mac[6];
        const uint8_t* a = dev->getAddress().getNative();
        if (!a) return;
        for (int i = 0; i < 6; i++) mac[i] = a[5 - i];
        axonCheckBleDevice(dev, mac, dev->getRSSI());
    }
};
static AxonBleCallback scanCb;

// ---------------------------------------------------------------------------
// Wi-Fi — the OUI shows up in the source address of any management frame, so
// probe requests and beacons are both covered without parsing either.

void axonCheckWifiISR(const uint8_t* payload, int len, int rssi, uint8_t channel) {
    if (!scanning || !payload || len < 16) return;
    const uint8_t* src = &payload[10];
    if (!axonMacMatches(src)) return;
    if (wifiDedupISR.check(src)) return;
    // Axon ships only duty equipment, so its OUI alone is a strong signal — but
    // one signal, so HIGH rather than VERIFIED.
    emit(src, rssi, channel, AXON_CONF_HIGH, "Axon (duty equipment)", true);
}

static void IRAM_ATTR axonWifiSnifferCb(void* buf, wifi_promiscuous_pkt_type_t type) {
    if (type != WIFI_PKT_MGMT) return;
    wifi_promiscuous_pkt_t* pkt = (wifi_promiscuous_pkt_t*)buf;
    if (!pkt) return;
    axonCheckWifiISR(pkt->payload, pkt->rx_ctrl.sig_len,
                     pkt->rx_ctrl.rssi, pkt->rx_ctrl.channel);
}

// ---------------------------------------------------------------------------
// Lifecycle

static void axonInit(void) {
    scanning = false;
    wifiActive = false;
}

static void axonStart(void) {
    scanning = true;
    bleDedup.setCooldownMs(engineGetRediscoverMs());
    wifiDedupISR.setCooldownMs(engineGetRediscoverMs());

    // If something else is already sweeping, ride along rather than contend.
    bool othersOwnRadio = (engineGetState(ENGINE_WARDRIVE) != ESTATE_DISABLED);
    bool wantBle  = (axonRadioMask & 0x02) != 0;
    bool wantWifi = (axonRadioMask & 0x01) != 0;

    if (!othersOwnRadio && wantBle) {
        bleScan = NimBLEDevice::getScan();
        bleCoexRegister(&scanCb, false);   // passive: these are ADV_IND payloads
        bleScan->setActiveScan(false);
        bleScan->setInterval(100);
        bleScan->setWindow(99);
    }

    if (!othersOwnRadio && wantWifi) {
        if (!meshIsEnabled()) WiFi.mode(WIFI_STA);
        wifiSnifferApplyPs();
        wifiApplyRegdomain();
        wifiCoexRegister(axonWifiSnifferCb, WIFI_PROMIS_FILTER_MASK_MGMT);
        channelIdx = 0;
        while (channelIdx < channelCount - 1 && !wifiChanEnabled(channels[channelIdx])) channelIdx++;
        esp_wifi_set_channel(channels[channelIdx], WIFI_SECOND_CHAN_NONE);
        lastChannelHop = millis();
        wifiActive = true;
    }

    const char* mode = othersOwnRadio ? "passive — fed by radio owner"
                     : (wantWifi && wantBle) ? "WiFi+BLE"
                     : wantWifi ? "WiFi only"
                     : wantBle  ? "BLE only" : "no radio";
    Serial.printf("[AXON] Started (%s)\n", mode);
}

static void axonStop(void) {
    scanning = false;

    if (wifiActive) {
        wifiActive = false;
        wifiCoexUnregister(axonWifiSnifferCb);
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
    Serial.println("[AXON] Stopped");
}

static void axonLoop(void) {
    if (meshIsEnabled() && (meshInMeshWindow() || meshInRidWindow())) return;
    if (!scanning) return;
    if (engineGetState(ENGINE_WARDRIVE) != ESTATE_DISABLED) return;

    if (wifiActive && wifiCoexShouldHop(ENGINE_AXON) &&
        millis() - lastChannelHop >= DWELL_MS) {
        int guard = 0;
        do {
            channelIdx = (channelIdx + 1) % channelCount;
        } while (!wifiChanEnabled(channels[channelIdx]) && ++guard < channelCount);
        esp_wifi_set_channel(channels[channelIdx], WIFI_SECOND_CHAN_NONE);
        lastChannelHop = millis();
        if (meshIsEnabled() && channels[channelIdx] == 1) meshNoteOnHome();
    }

    if (axonRadioMask & 0x02) bleCoexEnsureScanning();
}

static void axonConfig(const uint8_t* payload, uint8_t len) {
    if (!payload || len < 1) return;
    uint8_t mask = payload[0] & 0x03;
    if (mask == 0) mask = 0x03;
    if (mask == axonRadioMask) return;
    axonRadioMask = mask;
    Serial.printf("[AXON] Config radio mask=0x%02x\n", axonRadioMask);
    if (scanning) { axonStop(); axonStart(); }
}

static void axonApplyPrefs(void) {
    bleDedup.setCooldownMs(engineGetRediscoverMs());
    wifiDedupISR.setCooldownMs(engineGetRediscoverMs());
}

const EngineCallbacks axonCallbacks = {
    .init       = axonInit,
    .start      = axonStart,
    .stop       = axonStop,
    .loop       = axonLoop,
    .config     = axonConfig,
    .applyPrefs = axonApplyPrefs,
    .name       = "Axon"
};
