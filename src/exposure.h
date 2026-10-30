// SPDX-License-Identifier: MIT
#pragma once
// "What does my phone give away?" Pure logic for the exposure check, so it
// is unit tested on a PC (test/test_exposure).
//
// The board listens to probe requests while the user switches their own
// phone's Wi-Fi off and on. A phone turning Wi-Fi on scans at once, so its
// probes spike in the watch window against a quiet baseline. Probes are
// grouped by the layout of their tagged elements (each element's ID and
// length, leaving out the SSID and channel, which change from probe to
// probe), not by address: phones rotate the address between scans, but a
// phone's probe layout stays the same. The group that spikes most is the
// user's phone; what it named is what it leaks to anyone listening.
//
// Nothing is kept: the tables are cleared when the result is read, and no
// other device's data leaves this file.
#include <stdint.h>
#include <string.h>

#define EXPO_GROUPS     24
#define EXPO_SSIDS      8
#define EXPO_MIN_EXTRA  3       // probes above the baseline rate to name a phone

enum ExpoPhase : uint8_t { EXPO_IDLE = 0, EXPO_BASELINE, EXPO_WATCH, EXPO_DONE };

struct ExpoGroup {
    uint32_t layout;            // 0 = empty slot
    uint16_t base, watch;       // probes in each window
    bool     randomAddr;        // any probe from a locally administered address
    bool     globalAddr;        // any probe from the factory address
    uint8_t  nSsid;
    uint8_t  ssidLen[EXPO_SSIDS];
    char     ssid[EXPO_SSIDS][32];
};

struct ExpoState {
    ExpoPhase phase;
    ExpoGroup g[EXPO_GROUPS];
};

struct ExpoResult {
    bool     found;             // a phone stood out
    uint16_t probes;            // its probes in the watch window
    uint16_t extra;             // above what the baseline rate predicts
    bool     randomAddr, globalAddr;
    uint8_t  nSsid;
    uint8_t  ssidLen[EXPO_SSIDS];
    char     ssid[EXPO_SSIDS][32];
};

// Hash of the element layout of a probe request body (elements start at 24).
// Returns 0 for a frame too short to have any.
static inline uint32_t expoLayout(const uint8_t* p, int len) {
    uint32_t h = 2166136261u;                     // FNV-1a
    int n = 0;
    for (int o = 24; o + 2 <= len;) {
        uint8_t id = p[o], tl = p[o + 1];
        if (o + 2 + tl > len) break;
        if (id != 0 && id != 3) {
            h ^= id; h *= 16777619u;
            h ^= tl; h *= 16777619u;
            n++;
        }
        o += 2 + tl;
    }
    if (n == 0) return 0;
    return h ? h : 1u;
}

static inline void expoStart(ExpoState* s) {
    memset(s, 0, sizeof(*s));
    s->phase = EXPO_BASELINE;
}

// Feeds one probe request (frame control 0x40). Safe from the sniffer.
static inline void expoObserve(ExpoState* s, const uint8_t* p, int len) {
    if (s->phase != EXPO_BASELINE && s->phase != EXPO_WATCH) return;
    if (len < 26 || p[0] != 0x40) return;
    uint32_t layout = expoLayout(p, len);
    if (!layout) return;
    ExpoGroup* g = nullptr;
    for (int i = 0; i < EXPO_GROUPS; i++) {
        if (s->g[i].layout == layout) { g = &s->g[i]; break; }
        if (!g && s->g[i].layout == 0) g = &s->g[i];
    }
    if (!g) return;                               // table full: a very busy place
    if (g->layout == 0) g->layout = layout;
    if (s->phase == EXPO_BASELINE) { if (g->base < 0xFFFF) g->base++; return; }
    if (g->watch < 0xFFFF) g->watch++;
    if (p[10] & 0x02) g->randomAddr = true; else g->globalAddr = true;
    // The SSID element comes first in a probe request; empty is a wildcard.
    if (p[24] == 0 && p[25] > 0 && p[25] <= 32 && 26 + p[25] <= len) {
        uint8_t sl = p[25];
        for (int k = 0; k < g->nSsid; k++)
            if (g->ssidLen[k] == sl && memcmp(g->ssid[k], &p[26], sl) == 0) return;
        if (g->nSsid < EXPO_SSIDS) {
            memcpy(g->ssid[g->nSsid], &p[26], sl);
            g->ssidLen[g->nSsid++] = sl;
        }
    }
}

// Picks the group whose probes rose most above its baseline rate, scaled to
// the watch window's length, and clears the tables.
static inline ExpoResult expoFinish(ExpoState* s, uint32_t baseMs, uint32_t watchMs) {
    ExpoResult r;
    memset(&r, 0, sizeof(r));
    int best = -1;
    int32_t bestExtra = 0;
    for (int i = 0; i < EXPO_GROUPS; i++) {
        const ExpoGroup& g = s->g[i];
        if (!g.layout) continue;
        int32_t expected = baseMs ? (int32_t)((uint64_t)g.base * watchMs / baseMs) : 0;
        int32_t extra = (int32_t)g.watch - expected;
        if (extra > bestExtra) { bestExtra = extra; best = i; }
    }
    if (best >= 0 && bestExtra >= EXPO_MIN_EXTRA) {
        const ExpoGroup& g = s->g[best];
        r.found = true;
        r.probes = g.watch;
        r.extra = (uint16_t)bestExtra;
        r.randomAddr = g.randomAddr;
        r.globalAddr = g.globalAddr;
        r.nSsid = g.nSsid;
        memcpy(r.ssidLen, g.ssidLen, sizeof(r.ssidLen));
        memcpy(r.ssid, g.ssid, sizeof(r.ssid));
    }
    memset(s, 0, sizeof(*s));
    s->phase = EXPO_DONE;
    return r;
}

// Result as sent to the phone, after the opcode and phase bytes:
//   found[1] probes[2 LE] flags[1] (bit0 random address, bit1 factory address)
//   nSsid[1] then nSsid x (len[1] bytes[len])
// Returns the bytes written, at most 5 + EXPO_SSIDS * 33.
static inline int expoEncode(const ExpoResult* r, uint8_t* out, int cap) {
    if (cap < 5) return 0;
    int n = 0;
    out[n++] = r->found ? 1 : 0;
    out[n++] = (uint8_t)(r->probes & 0xFF);
    out[n++] = (uint8_t)(r->probes >> 8);
    out[n++] = (r->randomAddr ? 0x01 : 0) | (r->globalAddr ? 0x02 : 0);
    int countAt = n++;
    uint8_t written = 0;
    for (int k = 0; k < r->nSsid; k++) {
        if (n + 1 + r->ssidLen[k] > cap) break;
        out[n++] = r->ssidLen[k];
        memcpy(&out[n], r->ssid[k], r->ssidLen[k]);
        n += r->ssidLen[k];
        written++;
    }
    out[countAt] = written;
    return n;
}
