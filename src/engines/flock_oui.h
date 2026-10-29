// SPDX-License-Identifier: MIT
#ifndef FLOCK_OUI_H
#define FLOCK_OUI_H

#include <stdint.h>
#include <string.h>

// Upstream flock-you RSSI_MIN: frames weaker than this are dropped.
#define FLOCK_RSSI_MIN (-95)

extern volatile bool g_flockExtendedOui;

// The prefix list and its tiers are generated: see flock_oui_table.h.
#include "flock_oui_table.h"

struct FlockOuiBucket {
    uint8_t start;
    uint8_t count;
};

static FlockOuiBucket flockOuiBuckets[256];
static bool flockOuiBucketsReady = false;

static inline void flockOuiInitBuckets() {
    if (flockOuiBucketsReady) return;
    memset(flockOuiBuckets, 0, sizeof(flockOuiBuckets));
    for (int i = 0; i < FLOCK_OUI_COUNT; i++) {
        uint8_t b = FLOCK_OUI_TABLE[i].b[0];
        if (flockOuiBuckets[b].count == 0) {
            flockOuiBuckets[b].start = (uint8_t)i;
        }
        flockOuiBuckets[b].count++;
    }
    flockOuiBucketsReady = true;
}

// The matching prefix's FLOCK_OUI_* tier, or 0. EXT prefixes count only with
// the extended set switched on.
static inline uint8_t IRAM_ATTR flockMatchOuiISR(const uint8_t* mac) {
    if (mac[0] & 0x02) return 0;
    if (!flockOuiBucketsReady) return 0;
    const FlockOuiBucket& b = flockOuiBuckets[mac[0]];
    for (int i = b.start; i < b.start + b.count; i++) {
        if (mac[1] == FLOCK_OUI_TABLE[i].b[1] &&
            mac[2] == FLOCK_OUI_TABLE[i].b[2]) {
            uint8_t t = FLOCK_OUI_TABLE[i].tier;
            if (t == FLOCK_OUI_EXT && !g_flockExtendedOui) return 0;
            return t;
        }
    }
    return 0;
}

static inline int IRAM_ATTR isWildcardProbeIE(const uint8_t* body, int len) {
    if (!body || len < 2) return -1;
    while (len >= 2) {
        uint8_t id   = body[0];
        uint8_t elen = body[1];
        if ((int)elen + 2 > len) break;
        if (id == 0) return (elen == 0) ? 1 : 0;
        body += elen + 2;
        len  -= elen + 2;
    }
    return -1;
}

static inline bool IRAM_ATTR flockHasLiteonVendorIE(const uint8_t* body, int len) {
    if (!body) return false;
    while (len >= 2) {
        uint8_t id   = body[0];
        uint8_t elen = body[1];
        if ((int)elen + 2 > len) break;
        if (id == 221 && elen >= 3 &&
            body[2] == 0x50 && body[3] == 0x6f && body[4] == 0x9a) {
            return true;
        }
        body += elen + 2;
        len  -= elen + 2;
    }
    return false;
}

// --- flock-you exact IE fingerprint ---------------------------------------
//
// The high-confidence Flock signature is the exact ordered list of 802.11
// information-element tags in the camera's wildcard probe request, with vendor
// (221) elements expanded to their OUI+payload. This is the published
// flock-you method (colonelpanichacks/flock-you); it reports no false positives
// across long drive tests, at the cost of breaking if the camera firmware
// changes its IEs. The format string below is a data constant from that project
// (not copied code — the builder here is our own).
static const char FLOCK_PROBE_IE_SIG_PRIMARY[] =
    "2,12,127,221:506f9a16030103,45,191,221:0050f208000000";

static inline void flockHexByte(char* o, uint8_t b) {
    static const char h[] = "0123456789abcdef";
    o[0] = h[b >> 4];
    o[1] = h[b & 0x0F];
}

// Build the tag-list signature from a frame body. Skips the SSID element (tag
// 0) wherever it appears; vendor elements (221) become "221:" + up to 8 payload
// bytes in hex; every other element is its decimal tag number; comma-joined.
// Returns the written length.
static inline int flockBuildIeSig(const uint8_t* body, int len,
                                  char* out, int outsz) {
    int o = 0;
    bool first = true;
    while (len >= 2 && o < outsz - 1) {
        uint8_t id   = body[0];
        uint8_t elen = body[1];
        if ((int)elen + 2 > len) break;
        if (id == 0) { body += elen + 2; len -= elen + 2; continue; }
        if (!first && o < outsz - 1) out[o++] = ',';
        first = false;
        if (id == 221) {
            const char pre[] = "221:";
            for (int i = 0; i < 4 && o < outsz - 1; i++) out[o++] = pre[i];
            int n = elen > 8 ? 8 : elen;
            for (int i = 0; i < n && o < outsz - 2; i++) {
                flockHexByte(out + o, body[2 + i]);
                o += 2;
            }
        } else {
            char tmp[4];
            int t = 0, v = id;
            if (v == 0) tmp[t++] = '0';
            while (v > 0 && t < 3) { tmp[t++] = (char)('0' + v % 10); v /= 10; }
            while (t > 0 && o < outsz - 1) out[o++] = tmp[--t];
        }
        body += elen + 2;
        len  -= elen + 2;
    }
    out[o < outsz ? o : outsz - 1] = '\0';
    return o;
}

static inline bool flockStrEq(const char* a, const char* b) {
    while (*a && *b) { if (*a != *b) return false; a++; b++; }
    return *a == *b;
}

// True if the probe body's IE signature exactly matches the Flock primary. Tries
// the full body and, in case a 4-byte FCS trailer is present, the trimmed body.
// (Our builder skips SSID tag 0 anywhere, so flock-you's "skip leading empty
// SSID" second candidate is already covered.)
static inline bool flockProbeIeSigMatches(const uint8_t* body, int len) {
    char sig[80];
    flockBuildIeSig(body, len, sig, sizeof(sig));
    if (flockStrEq(sig, FLOCK_PROBE_IE_SIG_PRIMARY)) return true;
    if (len > 4) {
        flockBuildIeSig(body, len - 4, sig, sizeof(sig));
        if (flockStrEq(sig, FLOCK_PROBE_IE_SIG_PRIMARY)) return true;
    }
    return false;
}

#endif
