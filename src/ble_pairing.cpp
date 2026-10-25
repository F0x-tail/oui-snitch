// SPDX-License-Identifier: MIT
#include "ble_pairing.h"

#include <Arduino.h>
#include <Preferences.h>

#if defined(__has_include)
#  if __has_include(<NimBLEDevice.h>)
#    include <NimBLEDevice.h>
#    define OUISPY_HAVE_NIMBLE 1
#  endif
#endif

static const char* kPrefsNs = "ouispy-pair";
static const char* kPinKey  = "pin";

static uint32_t s_pin = BLE_PAIRING_DEFAULT_PIN;
static bool     s_loaded = false;

static void loadPin(void) {
    if (s_loaded) return;
    Preferences p;
    p.begin(kPrefsNs, true);
    uint32_t stored = p.getUInt(kPinKey, BLE_PAIRING_DEFAULT_PIN);
    p.end();
    s_pin = (stored <= BLE_PAIRING_PIN_MAX) ? stored : BLE_PAIRING_DEFAULT_PIN;
    s_loaded = true;
}

uint32_t blePairingPin(void) {
    loadPin();
    return s_pin;
}

bool blePairingIsDefault(void) {
    loadPin();
    return s_pin == BLE_PAIRING_DEFAULT_PIN;
}

bool blePairingSetPin(uint32_t pin) {
    if (pin > BLE_PAIRING_PIN_MAX) return false;

    Preferences p;
    p.begin(kPrefsNs, false);
    p.putUInt(kPinKey, pin);
    p.end();

    s_pin = pin;
    s_loaded = true;
#ifdef OUISPY_HAVE_NIMBLE
    // Takes effect for the next pairing. Phones already bonded hold working
    // keys and are not disturbed.
    NimBLEDevice::setSecurityPasskey(s_pin);
#endif
    Serial.printf("[PAIR] passkey changed to %06u\n", (unsigned)s_pin);
    return true;
}

void blePairingPrintBanner(void) {
    uint32_t pin = blePairingPin();
    Serial.println();
    Serial.println("========================================");
    Serial.printf ("  BLE pairing passkey: %06u\n", (unsigned)pin);
    if (blePairingIsDefault()) {
        Serial.println("  THIS IS THE DEFAULT. Anyone in range can");
        Serial.println("  pair with this board until you change it");
        Serial.println("  under Settings > Node in the app.");
    }
    Serial.println("========================================");
    Serial.println();
}

void blePairingReset(void) {
    Preferences p;
    p.begin(kPrefsNs, false);
    p.clear();
    p.end();
    s_pin = BLE_PAIRING_DEFAULT_PIN;
    s_loaded = true;
#ifdef OUISPY_HAVE_NIMBLE
    NimBLEDevice::deleteAllBonds();
    NimBLEDevice::setSecurityPasskey(s_pin);
#endif
    Serial.println("[PAIR] bonds cleared, passkey back to default");
}
