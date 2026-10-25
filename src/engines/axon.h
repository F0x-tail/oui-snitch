// SPDX-License-Identifier: MIT
#ifndef ENGINE_AXON_H
#define ENGINE_AXON_H

#include "engine_registry.h"

class NimBLEAdvertisedDevice;

extern const EngineCallbacks axonCallbacks;

// Dispatch hooks for when another engine owns the radio and this one has gone
// passive, mirroring the detector's arrangement: wardrive (and anything else
// already sweeping) hands frames over rather than each engine fighting for the
// radio. Safe to call when the engine is disabled — they no-op.
void axonCheckBleDevice(NimBLEAdvertisedDevice* dev, const uint8_t* mac, int rssi);
void axonCheckWifiISR(const uint8_t* payload, int len, int rssi, uint8_t channel);

// True while the engine is enabled, so radio owners know to dispatch.
bool axonIsActive(void);

// True when this engine wants the Wi-Fi radio (mask bit set), used by the
// registry's coex checks the same way detectorUsesWifi() is.
bool axonUsesWifi(void);

#endif
