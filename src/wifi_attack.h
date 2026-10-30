// SPDX-License-Identifier: MIT
#pragma once
// Wi-Fi attack behaviour, judged across frames: authentication floods,
// handshake harvesting, anonymous reassociation and forged channel switches.
// Fixed tables and an explicit clock, no ESP-IDF, so the rules run in the
// promiscuous callback and are unit tested on a PC (test/test_wifi_attack).
#include <stdint.h>
#include <string.h>
#include "wifi_frame.h"

// The trackers below are called from the IRAM frame handler but need not live
// in IRAM themselves (the handler runs in the Wi-Fi task, not an interrupt);
// keeping them out of line leaves them in flash, where there is room.
#define WIFI_ATTACK_FLASH __attribute__((noinline))

// Frame control byte 0 of the management subtypes involved.
#define WFC_ASSOC_REQ   0x00
#define WFC_REASSOC_REQ 0x20
#define WFC_PROBE_RESP  0x50
#define WFC_BEACON      0x80
#define WFC_AUTH        0xB0
#define WFC_ACTION      0xD0

// A transmitter address with the group bit set. No station sends from one;
// a request "from" broadcast is forged.
static inline bool wifiAddrIsGroup(const uint8_t* a) { return (a[0] & 0x01) != 0; }

// True for a station-to-AP join request: authentication, association or
// reassociation addressed to the BSS (receiver == BSSID, sender != BSSID).
// The AP's own replies are addressed the other way round and do not count.
static inline bool wifiIsJoinRequest(const uint8_t* p, int len) {
    if (len < 24) return false;
    uint8_t fc = p[0];
    if (fc != WFC_AUTH && fc != WFC_ASSOC_REQ && fc != WFC_REASSOC_REQ) return false;
    return memcmp(&p[4], &p[16], 6) == 0 && memcmp(&p[10], &p[16], 6) != 0;
}

// A Channel Switch Announcement: element 37 in a beacon or probe response,
// or an action frame of category Spectrum Management (0) or Public (4) with
// action 4 (Channel Switch / Extended Channel Switch). A genuine AP sends one
// only before moving channel, which on 2.4 GHz almost never happens; tools
// forge it to push clients off their network.
static inline bool wifiHasCsa(const uint8_t* p, int len) {
    if (len < 26) return false;
    if (p[0] == WFC_ACTION) return (p[24] == 0 || p[24] == 4) && p[25] == 4;
    if (p[0] != WFC_BEACON && p[0] != WFC_PROBE_RESP) return false;
    for (int o = 36; o + 2 <= len;) {
        uint8_t id = p[o], tl = p[o + 1];
        if (o + 2 + tl > len) break;
        if (id == 37) return true;
        o += 2 + tl;
    }
    return false;
}

// One bit of a 64-bit set per address, to count distinct addresses without
// storing them. Collisions only ever undercount, so a threshold on set bits
// is conservative.
static inline uint64_t wifiAddrBit(const uint8_t* a, int n) {
    uint32_t h = 2166136261u;                     // FNV-1a
    for (int i = 0; i < n; i++) { h ^= a[i]; h *= 16777619u; }
    return 1ull << (h & 63);
}
static inline uint8_t wifiBitCount(uint64_t v) {
    uint8_t n = 0;
    for (; v; v &= v - 1) n++;                   // no libgcc call from the callback
    return n;
}

// --- join requests: floods at one AP, and sweeps by one station ------------
//
//   Flood   many senders asking to join one AP within seconds, to fill its
//           client table. Real clients join once and stay.
//   Sweep   one sender joining many unrelated APs within a minute, the way
//           handshake/PMKID harvesters walk every network in range. A phone
//           roaming moves between APs of one network, which share a vendor,
//           so the sweep also needs several vendors.
//   Anon    a join request from a broadcast address. Some APs answer it by
//           deauthenticating every client, protected management frames or
//           not, so a flood after one is real even on a PMF network.
#define JOIN_FLOOD_WIN_MS   2000
#define JOIN_FLOOD_SENDERS  12      // set bits, i.e. at least 12 distinct senders
#define JOIN_SWEEP_WIN_MS   60000
#define JOIN_SWEEP_APS      6
#define JOIN_SWEEP_VENDORS  3
#define JOIN_ANON_RECENT_MS 10000
#define JOIN_REALERT_MS     60000   // one report per minute per AP or station
#define JOIN_SLOTS          8

enum JoinVerdict : uint8_t { JOIN_NONE = 0, JOIN_FLOOD, JOIN_SWEEP, JOIN_ANON };

struct JoinTarget {             // per AP
    uint8_t  bssid[6];
    uint64_t senders;
    uint32_t winStart;
    uint32_t anonMs;            // last anonymous request, 0 = never
    uint32_t floodAlertMs, anonAlertMs;   // 0 = never reported
    bool     used;
};
struct JoinSender {             // per station
    uint8_t  ta[6];
    uint64_t aps, vendors;
    uint32_t winStart;
    uint32_t alertMs;
    bool     used;
};
struct JoinWatch {
    JoinTarget t[JOIN_SLOTS];
    JoinSender s[JOIN_SLOTS];
};

// Finds the slot for [key] (6 bytes at [keyOff]), else claims a free one or
// the one whose window started longest ago.
template <typename T>
static inline T* joinSlot(T* slots, const uint8_t* key, size_t keyOff, uint32_t now, bool* fresh) {
    T* oldest = nullptr;
    for (int i = 0; i < JOIN_SLOTS; i++) {
        T* s = &slots[i];
        if (s->used && memcmp((const uint8_t*)s + keyOff, key, 6) == 0) { *fresh = false; return s; }
    }
    for (int i = 0; i < JOIN_SLOTS; i++) {
        T* s = &slots[i];
        if (!s->used) { oldest = s; break; }
        if (!oldest || (int32_t)(s->winStart - oldest->winStart) < 0) oldest = s;
    }
    memset(oldest, 0, sizeof(T));
    memcpy((uint8_t*)oldest + keyOff, key, 6);
    oldest->used = true;
    oldest->winStart = now;
    *fresh = true;
    return oldest;
}

static inline bool joinQuiet(uint32_t lastAlertMs, uint32_t now) {
    return lastAlertMs == 0 || now - lastAlertMs > JOIN_REALERT_MS;
}

// Feeds one join request (wifiIsJoinRequest). Returns the first verdict it
// completes; [count] gets the distinct senders (flood) or APs (sweep).
// Each verdict is reported at most once per JOIN_REALERT_MS per AP/station.
static WIFI_ATTACK_FLASH uint8_t joinObserve(JoinWatch* w, const uint8_t* p, uint32_t now,
                                            uint8_t* count) {
    const uint8_t* ta = &p[10];
    const uint8_t* bssid = &p[16];
    bool fresh;

    JoinTarget* t = joinSlot(w->t, bssid, offsetof(JoinTarget, bssid), now, &fresh);
    if (wifiAddrIsGroup(ta)) {
        t->anonMs = now ? now : 1;
        if (joinQuiet(t->anonAlertMs, now)) {
            t->anonAlertMs = now ? now : 1; *count = 1; return JOIN_ANON;
        }
        return JOIN_NONE;
    }
    if (now - t->winStart > JOIN_FLOOD_WIN_MS) { t->winStart = now; t->senders = 0; }
    t->senders |= wifiAddrBit(ta, 6);
    uint8_t senders = wifiBitCount(t->senders);

    JoinSender* s = joinSlot(w->s, ta, offsetof(JoinSender, ta), now, &fresh);
    if (now - s->winStart > JOIN_SWEEP_WIN_MS) { s->winStart = now; s->aps = s->vendors = 0; }
    s->aps |= wifiAddrBit(bssid, 6);
    // Vendor by OUI; a locally administered BSSID has no vendor, so it counts
    // as its own.
    s->vendors |= wifiAddrBit(bssid, (bssid[0] & 0x02) ? 6 : 3);

    if (senders >= JOIN_FLOOD_SENDERS && joinQuiet(t->floodAlertMs, now)) {
        t->floodAlertMs = now ? now : 1; *count = senders; return JOIN_FLOOD;
    }
    if (wifiBitCount(s->aps) >= JOIN_SWEEP_APS &&
        wifiBitCount(s->vendors) >= JOIN_SWEEP_VENDORS && joinQuiet(s->alertMs, now)) {
        s->alertMs = now ? now : 1; *count = wifiBitCount(s->aps); return JOIN_SWEEP;
    }
    return JOIN_NONE;
}

// True when [bssid] received an anonymous join request in the last few
// seconds: its own deauths then may be the attack working through PMF.
static inline bool joinAnonRecent(const JoinWatch* w, const uint8_t* bssid, uint32_t now) {
    for (int i = 0; i < JOIN_SLOTS; i++) {
        const JoinTarget* t = &w->t[i];
        if (t->used && t->anonMs && memcmp(t->bssid, bssid, 6) == 0)
            return now - t->anonMs <= JOIN_ANON_RECENT_MS;
    }
    return false;
}

// --- channel switch announcements ---------------------------------------
//
// A forged switch is a copy of the AP's beacon with element 37 added, sent
// beside the real AP, which keeps beaconing normally on the same channel. A
// real AP announcing a move puts the element in every beacon until it goes,
// and afterwards beacons on the new channel. So:
//   SUSPECTED  a switch announced on 2.4 GHz, where APs almost never move
//              (on 5 GHz radar forces moves, so a switch alone says nothing)
//   HIGH       a plain beacon from the same BSSID, for the same channel the
//              switch was announced on, within seconds of the switch
#define CSA_PAIR_MS  3000
#define CSA_SLOTS    4

enum CsaVerdict : uint8_t { CSA_NONE = 0, CSA_SUSPECT, CSA_FORGED };

struct CsaTrack {
    uint8_t  bssid[6];
    uint32_t lastCsaMs;
    uint8_t  channel;           // channel the AP claimed while announcing
    uint8_t  alerted;           // highest CsaVerdict reported
    bool     used;
};
struct CsaWatch { CsaTrack t[CSA_SLOTS]; };

// Feeds a beacon, probe response or action frame from an AP. [apChannel] is
// the channel the frame claims (apChannelFromFrame), or the tuned channel for
// an action frame. Returns a verdict to report, once per level per BSSID.
static WIFI_ATTACK_FLASH uint8_t csaObserve(CsaWatch* w, const uint8_t* p, int len,
                                           uint8_t apChannel, uint32_t now) {
    const uint8_t* bssid = &p[16];
    bool csa = wifiHasCsa(p, len);
    CsaTrack* hit = nullptr;
    for (int i = 0; i < CSA_SLOTS; i++)
        if (w->t[i].used && memcmp(w->t[i].bssid, bssid, 6) == 0) { hit = &w->t[i]; break; }
    if (!csa) {
        // The interesting case: the real AP still beaconing beside the copy.
        // Beacons only: an AP may leave the element out of probe responses.
        if (!hit || p[0] != WFC_BEACON || now - hit->lastCsaMs > CSA_PAIR_MS) return CSA_NONE;
        if (apChannel != hit->channel || hit->alerted >= CSA_FORGED) return CSA_NONE;
        hit->alerted = CSA_FORGED;
        return CSA_FORGED;
    }
    if (!hit) {
        hit = &w->t[0];
        for (int i = 0; i < CSA_SLOTS; i++) {
            if (!w->t[i].used) { hit = &w->t[i]; break; }
            if ((int32_t)(w->t[i].lastCsaMs - hit->lastCsaMs) < 0) hit = &w->t[i];
        }
        memset(hit, 0, sizeof(*hit));
        memcpy(hit->bssid, bssid, 6);
        hit->used = true;
    }
    hit->lastCsaMs = now;
    hit->channel = apChannel;
    if (apChannel >= 1 && apChannel <= 14 && hit->alerted < CSA_SUSPECT) {
        hit->alerted = CSA_SUSPECT;
        return CSA_SUSPECT;
    }
    return CSA_NONE;
}
