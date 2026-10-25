// SPDX-License-Identifier: MIT
#ifndef BLE_PAIRING_H
#define BLE_PAIRING_H

#include <stdint.h>

// LE Secure Connections pairing for the phone link.
//
// The passkey ships at a known default so a board works out of the box with no
// serial console, and the user changes it from the app. That means a board
// nobody has configured is pairable by anyone in range, so the app nags until
// it has been changed — see blePairingIsDefault().

#define BLE_PAIRING_DEFAULT_PIN 123456u
#define BLE_PAIRING_PIN_MAX     999999u

// The passkey currently in force.
uint32_t blePairingPin(void);

// True while the passkey is still the shipped default.
bool blePairingIsDefault(void);

// Change the passkey. Returns false if it is out of range. Existing bonds keep
// working — their keys are already exchanged — so this only affects phones
// that pair from here on.
bool blePairingSetPin(uint32_t pin);

// Print the passkey on the USB console.
void blePairingPrintBanner(void);

// Forget every bonded phone and return to the default passkey. Called by
// factory reset; every paired phone must pair again afterwards.
void blePairingReset(void);

#endif
