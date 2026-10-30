// SPDX-License-Identifier: MIT
#pragma once
// Followers that no signature knows, and followers that come back after the
// board was switched off. Pure logic, unit tested on a PC (test/test_follow).
//
// Generic follower (opt-in). Any Bluetooth device with a fixed address
// (public, or random static) that stays close and turns up in several
// places (place_epoch.h) is reported, whatever it is: cheap key finders,
// DIY GPS trackers, a stranger's OBD dongle. Phones rotate their address and
// drop out by themselves. Time alone never alerts, so sitting next to
// something for an hour does not; only moving with it does. Your own watch,
// earbuds and car will qualify too, which is what the ignore list is for.
//
// Memory across power cycles. A device that followed you to two places is
// remembered as a salted hash of its address (never the address). Seeing it
// again in a later session is evidence that builds over days.
#include <stdint.h>
#include <string.h>

#define FOLLOW_SLOTS      48
#define FOLLOW_PLACES     3          // places together before it is reported
#define FOLLOW_STALE_MS   3600000u   // forget a candidate unseen for an hour
#define FOLLOW_MIN_RSSI   (-75)      // close enough to be carried, not across the street

struct FollowCand {
    uint8_t  mac[6];
    uint32_t lastMs;
    uint16_t lastPlace;
    uint8_t  places;
    bool     reported;
    bool     used;
};
struct FollowTable { FollowCand c[FOLLOW_SLOTS]; };

// A fixed Bluetooth address: public, or random static (top two bits 11).
// Resolvable (01) and non-resolvable (00) private addresses rotate.
// [mac] is in display order, most significant byte first.
static inline bool followFixedAddress(const uint8_t* mac, bool randomType) {
    return !randomType || (mac[0] & 0xC0) == 0xC0;
}

// Which of two candidates to drop first: one seen in a single place before
// one that has already moved with you, then the longest unseen.
static inline bool followEvictBefore(const FollowCand* a, const FollowCand* b) {
    bool aLow = a->places < 2, bLow = b->places < 2;
    if (aLow != bLow) return aLow;
    return (int32_t)(a->lastMs - b->lastMs) < 0;
}

// Feeds one sighting in [place]. Returns the place count when this sighting
// makes the device a follower (once per device), else 0. [placesOut], if
// given, gets the device's place count either way.
static inline uint8_t followObserve(FollowTable* t, const uint8_t* mac, uint16_t place, uint32_t now,
                                    uint8_t* placesOut = nullptr) {
    FollowCand* hit = nullptr;
    FollowCand* victim = nullptr;
    for (int i = 0; i < FOLLOW_SLOTS; i++) {
        FollowCand* c = &t->c[i];
        if (c->used && now - c->lastMs > FOLLOW_STALE_MS) c->used = false;
        if (c->used && memcmp(c->mac, mac, 6) == 0) { hit = c; break; }
        if (!c->used) { if (!victim || victim->used) victim = c; continue; }
        if (victim && !victim->used) continue;     // a free slot beats any eviction
        if (!victim || followEvictBefore(c, victim)) victim = c;
    }
    if (!hit) {
        if (!victim) return 0;
        memset(victim, 0, sizeof(*victim));
        memcpy(victim->mac, mac, 6);
        victim->used = true;
        victim->places = 1;
        victim->lastPlace = place;
        hit = victim;
    } else if (hit->lastPlace != place) {
        hit->lastPlace = place;
        if (hit->places < 0xFF) hit->places++;
    }
    hit->lastMs = now;
    if (placesOut) *placesOut = hit->places;
    if (hit->reported || hit->places < FOLLOW_PLACES) return 0;
    hit->reported = true;
    return hit->places;
}

// --- memory across power cycles -------------------------------------------

#define FOLLOW_MEM_SLOTS 16

struct FollowMemRec {
    uint32_t id;                 // salted hash of the address, 0 = empty
    uint8_t  sessions;           // power-ups it was seen in
    uint8_t  spare;
};
struct FollowMem {
    uint32_t     salt;           // per install, so ids mean nothing elsewhere
    FollowMemRec r[FOLLOW_MEM_SLOTS];
    bool         seenThisBoot[FOLLOW_MEM_SLOTS];
    bool         dirty;          // needs saving
};

static inline uint32_t followMemId(uint32_t salt, const uint8_t* mac) {
    uint32_t h = 2166136261u ^ salt;              // FNV-1a, salted
    for (int i = 0; i < 6; i++) { h ^= mac[i]; h *= 16777619u; }
    return h ? h : 1u;
}

// Notes a sighting of a device that has been in [places] places this
// session. A remembered device seen for the first time this boot gains a
// session; a new one is remembered once it reaches two places. Returns the
// session count when it just went up past 1 (worth reporting), else 0.
static inline uint8_t followMemNote(FollowMem* m, const uint8_t* mac, uint8_t places) {
    uint32_t id = followMemId(m->salt, mac);
    int weakest = 0;
    for (int i = 0; i < FOLLOW_MEM_SLOTS; i++) {
        if (m->r[i].id == id) {
            if (m->seenThisBoot[i]) return 0;
            m->seenThisBoot[i] = true;
            if (m->r[i].sessions < 0xFF) m->r[i].sessions++;
            m->dirty = true;
            return m->r[i].sessions >= 2 ? m->r[i].sessions : 0;
        }
        if (m->r[i].sessions < m->r[weakest].sessions ||
            (m->r[weakest].id != 0 && m->r[i].id == 0)) weakest = i;
    }
    if (places < 2) return 0;
    m->r[weakest].id = id;
    m->r[weakest].sessions = 1;
    m->seenThisBoot[weakest] = true;
    m->dirty = true;
    return 0;
}
