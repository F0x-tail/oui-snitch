#ifndef TRACKER_RING_H
#define TRACKER_RING_H

#include <stdint.h>

// Force a nearby tracker to play its sound, so a hidden one can be located.
//
// Counter-surveillance only. Connects to the tracker as a BLE central and
// writes the vendor "play sound" command. Public protocol, from AirGuard
// (TU Darmstadt SEEMOO lab, Apache-2.0).
//
// This TRANSMITS and is the deliberate exception to passive-by-default: it is
// only ever started by an explicit user request, never automatically. It only
// works on a tracker that is separated from its owner — which a tracker
// following the user is, by definition.

enum TrackerRingHint : uint8_t {
    RING_HINT_AUTO    = 0,  // try DULT, then FindMy, then legacy AirTag
    RING_HINT_DULT    = 1,  // cross-vendor: newer Find My, SmartTag, Tile, Chipolo
    RING_HINT_FINDMY  = 2,  // Apple Find My accessory (fd44)
    RING_HINT_AIRTAG  = 3,  // legacy AirTag
};

// Start a one-shot ring of [mac] (6 bytes). Non-blocking: runs on its own task,
// pausing the scan engines for its duration and restoring them after. A ring
// already in progress is refused.
void trackerRingStart(const uint8_t mac[6], uint8_t hint);

bool trackerRingBusy(void);

#endif // TRACKER_RING_H
