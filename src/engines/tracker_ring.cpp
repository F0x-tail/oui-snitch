#include "tracker_ring.h"
#include "../protocol.h"
#include "../engine_registry.h"
#include "../ble_coex.h"
#include <Arduino.h>
#include <NimBLEDevice.h>
#include <string.h>

// --- public GATT definitions (AirGuard, Apache-2.0) ------------------------

static const char* DULT_SVC  = "15190001-12F4-C226-88ED-2AC5579F2A85";
static const char* DULT_CHR  = "8E0C0001-1D68-FB92-BF61-48377421680E";
static const char* FINDMY_CHR = "4F860003-943B-49EF-BED4-2F730304427A";
static const char* AIRTAG_SVC = "7DFC9000-7D1C-4951-86AA-8D9728F8D66C";
static const char* AIRTAG_CHR = "7DFC9001-7D1C-4951-86AA-8D9728F8D66C";

static const uint8_t DULT_START[]   = {0x00, 0x03};
static const uint8_t DULT_STOP[]    = {0x01, 0x03};
static const uint8_t FINDMY_START[] = {0x01, 0x00, 0x03};
static const uint8_t FINDMY_STOP[]  = {0x01, 0x01, 0x03};
static const uint8_t AIRTAG_TRIG[]  = {0xAF};

static volatile bool s_busy = false;
static uint8_t s_mac[6];
static uint8_t s_hint;

bool trackerRingBusy(void) { return s_busy; }

static bool ringWriteWithStop(NimBLEClient* cli, const char* svcUuid,
                              const char* chrUuid,
                              const uint8_t* start, size_t startLen,
                              const uint8_t* stop, size_t stopLen) {
    NimBLERemoteService* svc =
        svcUuid ? cli->getService(NimBLEUUID(svcUuid)) : nullptr;
    if (svcUuid && !svc) {
        Serial.printf("[RING]   service %.8s... not present\n", svcUuid);
    }
    NimBLERemoteCharacteristic* chr = nullptr;
    if (svc) {
        chr = svc->getCharacteristic(NimBLEUUID(chrUuid));
        if (!chr) Serial.printf("[RING]   char %.8s... not present\n", chrUuid);
    } else {
        // FindMy: the characteristic lives under a service whose UUID we do not
        // fix (advertised fd44 variant). Search every service for the char.
        const std::vector<NimBLERemoteService*>& services = cli->getServices(true);
        for (auto* s : services) {
            auto* c = s->getCharacteristic(NimBLEUUID(chrUuid));
            if (c) { chr = c; break; }
        }
    }
    if (!chr) return false;

    Serial.printf("[RING]   found char, writing %u-byte start\n",
                  (unsigned)startLen);
    // Best-effort CCCD enable; the sound still fires if notifications are absent.
    if (chr->canNotify() || chr->canIndicate()) {
        chr->subscribe(chr->canNotify());
        delay(100);
    }
    if (!chr->writeValue(start, startLen, true)) {
        Serial.println("[RING]   write REJECTED by the device");
        return false;
    }
    delay(5000);
    if (stop && stopLen) chr->writeValue(stop, stopLen, true);
    return true;
}

static bool ringOnce(NimBLEClient* cli, uint8_t hint) {
    // AUTO walks the families in priority order; a hint pins one.
    if (hint == RING_HINT_AUTO || hint == RING_HINT_DULT) {
        if (ringWriteWithStop(cli, DULT_SVC, DULT_CHR,
                              DULT_START, sizeof(DULT_START),
                              DULT_STOP, sizeof(DULT_STOP))) {
            Serial.println("[RING] DULT sound sent");
            return true;
        }
        if (hint == RING_HINT_DULT) return false;
    }
    if (hint == RING_HINT_AUTO || hint == RING_HINT_FINDMY) {
        if (ringWriteWithStop(cli, nullptr, FINDMY_CHR,
                              FINDMY_START, sizeof(FINDMY_START),
                              FINDMY_STOP, sizeof(FINDMY_STOP))) {
            Serial.println("[RING] FindMy sound sent");
            return true;
        }
        if (hint == RING_HINT_FINDMY) return false;
    }
    if (hint == RING_HINT_AUTO || hint == RING_HINT_AIRTAG) {
        if (ringWriteWithStop(cli, AIRTAG_SVC, AIRTAG_CHR,
                              AIRTAG_TRIG, sizeof(AIRTAG_TRIG),
                              nullptr, 0)) {
            Serial.println("[RING] legacy AirTag trigger sent");
            return true;
        }
    }
    return false;
}

static void ringTask(void* arg) {
    (void)arg;
    // Free the radio: remember what was running, stop it, restore afterwards.
    const uint8_t savedMask = engineGetActiveMask();
    engineDisableAll();
    delay(300);

    NimBLEClient* cli = NimBLEDevice::createClient();
    bool ok = false;

    // Trackers use random static addresses; try that first, then public.
    const uint8_t addrTypes[] = {BLE_ADDR_RANDOM, BLE_ADDR_PUBLIC};
    for (uint8_t ti = 0; ti < 2 && !ok; ti++) {
        NimBLEAddress addr(s_mac, addrTypes[ti]);
        Serial.printf("[RING] connecting %s (type %u)\n",
                      addr.toString().c_str(), addrTypes[ti]);
        if (!cli->connect(addr, true)) {
            Serial.println("[RING]   connect refused / no response");
            continue;
        }
        Serial.println("[RING]   connected — discovering services");
        delay(400);
        const std::vector<NimBLERemoteService*>& svcs = cli->getServices(true);
        Serial.printf("[RING]   %u services advertised\n", (unsigned)svcs.size());
        for (auto* sv : svcs) {
            Serial.printf("[RING]     %s\n", sv->getUUID().toString().c_str());
        }
        ok = ringOnce(cli, s_hint);
        cli->disconnect();
        delay(200);
        if (ok) break;
    }
    if (!ok) Serial.println("[RING] failed — tracker not separated, out of range, or unsupported");

    NimBLEDevice::deleteClient(cli);

    // Restore the engines that were running.
    for (int i = 0; i < ENGINE_COUNT; i++) {
        if (savedMask & ENGINE_BITMASK(i)) engineEnable((EngineId)i);
    }
    bleCoexEnsureScanning();

    s_busy = false;
    vTaskDelete(NULL);
}

void trackerRingStart(const uint8_t mac[6], uint8_t hint) {
    if (s_busy) { Serial.println("[RING] busy — ignored"); return; }
    s_busy = true;
    memcpy(s_mac, mac, 6);
    s_hint = hint;
    Serial.printf("[RING] requested %02X:%02X:%02X:%02X:%02X:%02X hint=%u\n",
                  mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], hint);
    xTaskCreate(ringTask, "trackerRing", 8192, nullptr, 5, nullptr);
}
