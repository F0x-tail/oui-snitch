// SPDX-License-Identifier: MIT
#ifndef AXON_MATCH_H
#define AXON_MATCH_H

#include <stdint.h>
#include <string.h>
#include "../protocol.h"

// Axon / TASER duty-equipment matching, shared by two callers:
//   * the detector engine's SIG_AXON branch (one signature among many)
//   * the dedicated Axon engine (ENGINE_AXON), which is the same matching with
//     its own tile, radio slice and presence buzzer
//
// Keeping the signatures here means there is one implementation to correct when
// a vendor ID or UUID changes, instead of two that can drift apart.
//
// Four independent signals, all registered to Axon Enterprise / TASER:
//   * MAC OUI 00:25:DF, on either radio   (AXON_OUI)
//   * BLE manufacturer company ID 0x034D  (TASER International)
//   * BLE service UUIDs FC81 / FE6B / FE6C
//
// A bare OUI is strong here in a way it is not for most vendors: Axon ships
// only duty equipment, so the block does not cover unrelated consumer gear.
// Other law-enforcement radio vendors are deliberately *not* treated this way —
// see LE_VENDOR_OUIS in detector.cpp, where a Motorola block stays SUSPECTED
// because it covers a great deal besides police radios.

// Mirrors DET_CONF_* so a tier from here can be assigned straight into
// DetectionEvent.ext.detector.confidence by either caller. The asserts keep the
// two from drifting apart silently.
enum AxonConf : uint8_t {
    AXON_CONF_NONE      = 0,
    AXON_CONF_SUSPECTED = 1,
    AXON_CONF_HIGH      = 2,
    AXON_CONF_VERIFIED  = 3,
};
static_assert((int)AXON_CONF_NONE      == DET_CONF_NONE,      "axon tier drift");
static_assert((int)AXON_CONF_SUSPECTED == DET_CONF_SUSPECTED, "axon tier drift");
static_assert((int)AXON_CONF_HIGH      == DET_CONF_HIGH,      "axon tier drift");
static_assert((int)AXON_CONF_VERIFIED  == DET_CONF_VERIFIED,  "axon tier drift");

static const uint8_t AXON_OUI[3] = { 0x00, 0x25, 0xdf };

// TASER International, from the Bluetooth SIG company identifier list.
static const uint16_t AXON_MFG_ID = 0x034D;

// Service UUIDs registered to Axon/TASER.
static const uint16_t AXON_SVC_UUIDS[] = { 0xFC81, 0xFE6B, 0xFE6C };

static inline bool axonMacMatches(const uint8_t* mac) {
    return mac && memcmp(mac, AXON_OUI, 3) == 0;
}

static inline bool axonSvcUuidMatches(uint16_t uuid) {
    for (unsigned i = 0; i < sizeof(AXON_SVC_UUIDS) / sizeof(AXON_SVC_UUIDS[0]); i++) {
        if (AXON_SVC_UUIDS[i] == uuid) return true;
    }
    return false;
}

// Manufacturer-data blob as advertised: first two bytes are the company ID,
// little-endian. Returns false for anything shorter.
static inline bool axonMfgMatches(const uint8_t* mfg, size_t len) {
    if (!mfg || len < 2) return false;
    uint16_t cid = (uint16_t)(mfg[0] | (mfg[1] << 8));
    return cid == AXON_MFG_ID;
}

// Fold the independent signals into one confidence tier.
//   vendor-specific ID/UUID *and* the Axon OUI   -> VERIFIED
//   either one alone                             -> HIGH
//   neither (caller matched some other LE vendor)-> SUSPECTED, caller's call
static inline uint8_t axonConfidence(bool mfgOrSvc, bool macHit) {
    if (mfgOrSvc && macHit) return AXON_CONF_VERIFIED;
    if (mfgOrSvc || macHit) return AXON_CONF_HIGH;
    return AXON_CONF_NONE;
}

#endif
