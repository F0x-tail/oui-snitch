// SPDX-License-Identifier: MIT
#include "exposure_check.h"
#include "../exposure.h"
#include "../engine_registry.h"
#include "../radio_coex.h"
#include "../ble_coex.h"
#include "../wifi_frame.h"
#include <Arduino.h>
#include <esp_wifi.h>

static const uint32_t BASE_MS  = 6000;    // how busy the air is before
static const uint32_t WATCH_MS = 15000;   // time for the user to switch Wi-Fi off and on
static const uint32_t HOP_MS   = 250;
// Phones scan every 2.4 GHz channel when Wi-Fi comes on; three cover it.
static const uint8_t  HOP[]    = {1, 6, 11};

static ExpoState s_expo;
static ExposureNotify s_notify = nullptr;
static volatile bool s_busy = false;

static void IRAM_ATTR expoSnifferCb(void* buf, wifi_promiscuous_pkt_type_t type) {
    if (type != WIFI_PKT_MGMT) return;
    wifi_promiscuous_pkt_t* pkt = (wifi_promiscuous_pkt_t*)buf;
    expoObserve(&s_expo, pkt->payload, wifiFrameLen(pkt->rx_ctrl.sig_len));
}

static void sendPhase(ExpoPhase phase) {
    uint8_t b[2] = {SYS_OP_EXPOSURE, (uint8_t)phase};
    if (s_notify) s_notify(b, sizeof(b));
}

static void listen(uint32_t ms) {
    uint32_t start = millis();
    uint8_t i = 0;
    while (millis() - start < ms) {
        esp_wifi_set_channel(HOP[i++ % sizeof(HOP)], WIFI_SECOND_CHAN_NONE);
        delay(HOP_MS);
    }
}

static void exposureTask(void*) {
    const uint8_t savedMask = engineGetActiveMask();
    engineDisableAll();
    delay(300);

    expoStart(&s_expo);
    wifiCoexRegister(expoSnifferCb, WIFI_PROMIS_FILTER_MASK_MGMT);
    sendPhase(EXPO_BASELINE);
    listen(BASE_MS);
    s_expo.phase = EXPO_WATCH;
    sendPhase(EXPO_WATCH);
    listen(WATCH_MS);
    s_expo.phase = EXPO_IDLE;           // the sniffer stops adding before we read
    wifiCoexUnregister(expoSnifferCb);
    delay(50);

    ExpoResult r = expoFinish(&s_expo, BASE_MS, WATCH_MS);
    uint8_t out[2 + 5 + EXPO_SSIDS * 33];
    out[0] = SYS_OP_EXPOSURE;
    out[1] = EXPO_DONE;
    int n = 2 + expoEncode(&r, &out[2], sizeof(out) - 2);
    if (s_notify) s_notify(out, n);
    // Counts only: the names are the user's own and stay off the serial log.
    Serial.printf("[EXPO] done: %s, %u probes, %u names\n",
                  r.found ? "phone found" : "no clear phone", (unsigned)r.probes, (unsigned)r.nSsid);
    memset(&r, 0, sizeof(r));
    memset(out, 0, sizeof(out));

    for (int i = 0; i < ENGINE_COUNT; i++) {
        if (savedMask & ENGINE_BITMASK(i)) engineEnable((EngineId)i);
    }
    bleCoexEnsureScanning();
    s_busy = false;
    vTaskDelete(NULL);
}

void exposureCheckStart(ExposureNotify notify) {
    if (s_busy) { Serial.println("[EXPO] busy — ignored"); return; }
    s_busy = true;
    s_notify = notify;
    Serial.println("[EXPO] started");
    xTaskCreate(exposureTask, "exposure", 6144, nullptr, 5, nullptr);
}

bool exposureCheckBusy(void) { return s_busy; }
