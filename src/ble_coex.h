// SPDX-License-Identifier: MIT
#pragma once
#include <NimBLEDevice.h>

void bleCoexRegister(NimBLEAdvertisedDeviceCallbacks* cb, bool activeScan);
void bleCoexUnregister(NimBLEAdvertisedDeviceCallbacks* cb);
NimBLEScan* bleCoexScan(void);
bool bleCoexActive(void);
void bleCoexEnsureScanning(void);
void bleCoexPauseForMesh(void);

// The one place that decides whether a BLE scan may transmit. An active scan
// sends a scan request to every advertiser it hears — including the devices
// being detected — and each request carries this board's address. Engines ask
// for active scanning because it returns device names; the user can override
// that with passive scanning, which only listens. Every engine sets its scan
// mode through this, never through NimBLEScan::setActiveScan directly.
void bleScanSetActive(NimBLEScan* s, bool wantActive);
void bleSetPassiveScan(bool passive);
bool bleGetPassiveScan(void);
