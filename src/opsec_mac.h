// SPDX-License-Identifier: MIT
#pragma once

#include <Arduino.h>
#include <esp_mac.h>

// A board that keeps its factory MAC is trackable across every place it is
// switched on, by anyone within radio range, forever. A fresh locally
// administered base MAC each boot removes that for Wi-Fi and ESP-NOW.
//
// Bluetooth does not use it. A new Bluetooth address every boot invalidated
// every bond, so the phone asked for the passkey after each reboot. BLE
// advertises from a random static address that is generated once and kept
// instead (bleUseStableAddress in ble_gatt.cpp). The app still falls back to
// scanning for a board of the same role and verifying its node id
// (BleManager._scanForSameRole) for any address it cannot find.

inline uint8_t g_factoryBtMac[6] = {0};
inline bool g_factoryBtMacSet = false;

inline void opsecRandomizeBaseMac(void) {
    // Keep the factory BT MAC: it is still the board's durable identity for
    // anything that must survive a reboot, and it cannot be read back once the
    // base MAC is replaced.
    esp_read_mac(g_factoryBtMac, ESP_MAC_BT);
    g_factoryBtMacSet = true;

    uint8_t m[6];
    uint32_t a = esp_random(), b = esp_random();
    // Bit 1 of the first octet marks the address locally administered, bit 0
    // keeps it unicast. Anything else would claim an OUI we do not own.
    m[0] = (uint8_t)((a & 0xFC) | 0x02);
    m[1] = (uint8_t)(a >> 8);
    m[2] = (uint8_t)(a >> 16);
    m[3] = (uint8_t)(a >> 24);
    m[4] = (uint8_t)b;
    // Interface addresses are derived by adding 0..3 to the base, so the low
    // two bits are left clear to keep that addition from carrying into the
    // byte above. Clearing more than that would be a constant in every
    // address we emit — a fingerprint inside the anti-fingerprinting.
    m[5] = (uint8_t)((b >> 8) & 0xFC);

    esp_err_t err = esp_base_mac_addr_set(m);
    Serial.printf("[OPSEC] base MAC randomized: %s\n",
                  err == ESP_OK ? "ok" : esp_err_to_name(err));
}

inline void opsecFactoryBtMac(uint8_t out[6]) {
    if (g_factoryBtMacSet) memcpy(out, g_factoryBtMac, 6);
    else esp_read_mac(out, ESP_MAC_BT);
}
