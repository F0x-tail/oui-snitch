// SPDX-License-Identifier: MIT
#pragma once
// Places without GPS. Pure logic, unit tested on a PC (test/test_place_epoch).
//
// Being near a tag for five minutes says nothing about being followed: you
// may simply be sitting next to someone. Being near it in three different
// places does. With no position to go on, the board tells places apart by
// what it hears: the mix of Bluetooth vendors around it and how many devices
// there are. A café, a train and a home sound different.
//
// Every window the board builds a profile: distinct devices (one bit each in
// a 512-bit set) and a vendor histogram counted once per device (company ID
// hashed into buckets, plus one for devices with no manufacturer data). It
// is compared with the current place's profile:
//
//   drift = 0.7 x (half the L1 distance between the vendor mixes)
//         + 0.3 x |change in device count| / larger count
//
// Above PLACE_DRIFT, and at least PLACE_MIN_MS after the last change, a new
// place begins. Otherwise the window is folded into the place's profile, so
// a slow change (a café filling up) does not add up to a move. A board left
// in one spot stays in one place. Idea after Simulacra's drift model.
#include <stdint.h>
#include <string.h>

#define PLACE_WIN_MS     120000u   // one profile every two minutes
#define PLACE_MIN_MS     600000u   // at least ten minutes in a place
#define PLACE_DRIFT      0.45f
#define PLACE_MIN_POP    3         // fewer devices than this is no profile
#define PLACE_BUCKETS    17        // 16 vendor buckets + "no manufacturer data"
#define PLACE_NO_MFG     0xFFFFu

struct PlaceWindow {
    uint32_t seen[16];             // 512-bit set of device addresses
    uint16_t vendor[PLACE_BUCKETS];
    uint16_t pop;
};

struct PlaceState {
    uint16_t epoch;                // current place number, starts at 1
    uint32_t epochStart;
    uint32_t winStart;
    bool     haveRef;
    float    refMix[PLACE_BUCKETS];
    float    refPop;
    PlaceWindow w;
};

static inline uint8_t placeBucket(uint16_t companyId) {
    if (companyId == PLACE_NO_MFG) return PLACE_BUCKETS - 1;
    return (uint8_t)(((uint32_t)companyId * 2654435761u) >> 28);   // 0..15
}

static inline void placeInit(PlaceState* s, uint32_t now) {
    memset(s, 0, sizeof(*s));
    s->epoch = 1;
    s->epochStart = now;
    s->winStart = now;
}

// Drift between a finished window and the place's profile, 0..1.
static inline float placeDrift(const PlaceState* s) {
    float l1 = 0;
    for (int b = 0; b < PLACE_BUCKETS; b++) {
        float m = s->w.pop ? (float)s->w.vendor[b] / s->w.pop : 0;
        float d = m - s->refMix[b];
        l1 += d < 0 ? -d : d;
    }
    float pop = s->w.pop, big = pop > s->refPop ? pop : s->refPop;
    float dPop = big > 0 ? (pop > s->refPop ? pop - s->refPop : s->refPop - pop) / big : 0;
    return 0.7f * 0.5f * l1 + 0.3f * dPop;
}

// Closes the window: compare, then start a new place or fold the window in.
// Returns true when a new place began.
static inline bool placeRoll(PlaceState* s, uint32_t now) {
    bool moved = false;
    if (s->w.pop >= PLACE_MIN_POP) {
        if (!s->haveRef) {
            s->haveRef = true;
            s->refPop = s->w.pop;
            for (int b = 0; b < PLACE_BUCKETS; b++) s->refMix[b] = (float)s->w.vendor[b] / s->w.pop;
        } else {
            float drift = placeDrift(s);
            if (drift > PLACE_DRIFT && now - s->epochStart >= PLACE_MIN_MS) {
                moved = true;
                s->epoch = s->epoch == 0xFFFF ? 1 : s->epoch + 1;
                s->epochStart = now;
                s->refPop = s->w.pop;
                for (int b = 0; b < PLACE_BUCKETS; b++) s->refMix[b] = (float)s->w.vendor[b] / s->w.pop;
            } else {
                s->refPop = 0.7f * s->refPop + 0.3f * s->w.pop;
                for (int b = 0; b < PLACE_BUCKETS; b++)
                    s->refMix[b] = 0.7f * s->refMix[b] + 0.3f * (float)s->w.vendor[b] / s->w.pop;
            }
        }
    }
    memset(&s->w, 0, sizeof(s->w));
    s->winStart = now;
    return moved;
}

// Feeds one advertisement. [companyId] is the manufacturer data's company
// ID, or PLACE_NO_MFG. Returns true when this call started a new place.
static inline bool placeObserve(PlaceState* s, const uint8_t* mac, uint16_t companyId, uint32_t now) {
    bool moved = false;
    if (now - s->winStart >= PLACE_WIN_MS) moved = placeRoll(s, now);
    uint32_t h = 2166136261u;                     // FNV-1a over the address
    for (int i = 0; i < 6; i++) { h ^= mac[i]; h *= 16777619u; }
    uint32_t bit = h & 511;
    uint32_t mask = 1u << (bit & 31);
    if (s->w.seen[bit >> 5] & mask) return moved;  // this device already counted
    s->w.seen[bit >> 5] |= mask;
    if (s->w.pop < 0xFFFF) s->w.pop++;
    uint8_t b = placeBucket(companyId);
    if (s->w.vendor[b] < 0xFFFF) s->w.vendor[b]++;
    return moved;
}
