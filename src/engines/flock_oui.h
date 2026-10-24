#ifndef FLOCK_OUI_H
#define FLOCK_OUI_H

#include <stdint.h>
#include <string.h>

struct FlockOui { uint8_t b[3]; uint8_t ext; };

// Upstream flock-you RSSI_MIN: frames weaker than this are dropped.
#define FLOCK_RSSI_MIN (-95)

extern volatile bool g_flockExtendedOui;

static const FlockOui FLOCK_OUI_TABLE[] = {
    { {0x00,0x03,0x7f}, 1 }, // Qualcomm Atheros QCA9377 (Flock fw default MAC)
    { {0x00,0x18,0x0a}, 1 }, // Murata
    { {0x00,0x23,0x6c}, 1 }, // Sierra Wireless
    { {0x00,0x40,0x8c}, 1 }, // Flock BLE (@NitekryDPaul Jul 2026 LE CSV)
    { {0x00,0xf4,0x8d}, 0 }, // Cradlepoint
    { {0x04,0x0d,0x84}, 1 }, // Cradlepoint
    { {0x08,0x3a,0x88}, 0 },
    { {0x14,0x5a,0xfc}, 0 },
    { {0x14,0xb5,0xcd}, 1 },
    { {0x1c,0x34,0xf1}, 1 },
    { {0x1c,0xb7,0x2c}, 1 }, // Murata
    { {0x24,0x0a,0xc4}, 1 }, // Espressif
    { {0x24,0x6f,0x28}, 1 }, // Espressif
    { {0x24,0xb2,0xb9}, 0 },
    { {0x2c,0xf4,0x32}, 1 }, // Espressif
    { {0x30,0xae,0xa4}, 1 }, // Espressif
    { {0x38,0x5b,0x44}, 1 },
    { {0x3c,0x61,0x05}, 1 }, // Espressif
    { {0x3c,0x71,0xbf}, 0 },
    { {0x3c,0x91,0x80}, 0 },
    { {0x48,0x27,0xea}, 0 },
    { {0x58,0x00,0xe3}, 0 },
    { {0x58,0x8e,0x81}, 0 },
    { {0x5c,0x93,0xa2}, 0 },
    { {0x60,0x62,0x01}, 1 }, // Sierra Wireless
    { {0x64,0x6e,0x69}, 0 },
    { {0x70,0x08,0x94}, 0 }, // Espressif
    { {0x70,0xc9,0x4e}, 0 },
    { {0x74,0x4c,0xa1}, 0 },
    { {0x80,0x30,0x49}, 0 },
    { {0x82,0x6b,0xf2}, 0 },
    { {0x84,0x0d,0x8e}, 1 }, // Espressif
    { {0x84,0xf3,0xeb}, 1 }, // Espressif
    { {0x8c,0xaa,0xb5}, 1 }, // Espressif
    { {0x90,0x35,0xea}, 0 },
    { {0x94,0x08,0x53}, 0 },
    { {0x94,0x34,0x69}, 1 }, // Espressif
    { {0x98,0xf4,0xab}, 1 }, // Espressif
    { {0x9c,0x2f,0x9d}, 0 },
    { {0x9c,0x9c,0x1f}, 1 }, // Espressif
    { {0xa0,0xc9,0xa0}, 1 }, // Murata
    { {0xa4,0xcf,0x12}, 0 }, // Espressif
    { {0xac,0x67,0xb2}, 1 }, // Espressif
    { {0xac,0xcc,0x8e}, 1 }, // Flock BLE (@NitekryDPaul Jul 2026 LE CSV)
    { {0xb4,0x1e,0x52}, 1 }, // Flock Group Inc. (direct)
    { {0xb4,0xe3,0xf9}, 1 },
    { {0xb8,0x1e,0xa4}, 0 },
    { {0xb8,0x35,0x32}, 0 },
    { {0xbc,0xdd,0xc2}, 1 }, // Espressif
    { {0xc0,0x35,0x32}, 0 },
    { {0xc8,0x2b,0x96}, 1 }, // Espressif
    { {0xcc,0x50,0xe3}, 1 }, // Espressif
    { {0xd0,0x39,0x57}, 0 },
    { {0xd4,0x11,0xd6}, 1 },
    { {0xd8,0xa0,0x1d}, 1 }, // Espressif
    { {0xd8,0xf3,0xbc}, 0 },
    { {0xdc,0x54,0x75}, 1 }, // Espressif
    { {0xe0,0x0a,0xf6}, 1 },
    { {0xe0,0x4f,0x43}, 0 },
    { {0xe4,0xaa,0xea}, 0 }, // Liteon
    { {0xe8,0xd0,0xfc}, 0 },
    { {0xec,0x1b,0xbd}, 0 },
    { {0xec,0x62,0x60}, 1 }, // Espressif
    { {0xf0,0x82,0xc0}, 1 },
    { {0xf4,0x6a,0xdd}, 0 },
    { {0xf4,0xcf,0xa2}, 1 }, // Espressif
    { {0xf8,0xa2,0xd6}, 1 },
    { {0xfc,0xf5,0xc4}, 1 }, // Espressif
};
static const int FLOCK_OUI_COUNT = sizeof(FLOCK_OUI_TABLE) / sizeof(FLOCK_OUI_TABLE[0]);

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

static inline bool flockMatchOui(const uint8_t* mac) {
    if (mac[0] & 0x02) return false;
    if (!flockOuiBucketsReady) flockOuiInitBuckets();
    const FlockOuiBucket& b = flockOuiBuckets[mac[0]];
    for (int i = b.start; i < b.start + b.count; i++) {
        if (mac[1] == FLOCK_OUI_TABLE[i].b[1] &&
            mac[2] == FLOCK_OUI_TABLE[i].b[2]) {
            if (FLOCK_OUI_TABLE[i].ext && !g_flockExtendedOui) continue;
            return true;
        }
    }
    return false;
}

static inline bool IRAM_ATTR flockMatchOuiISR(const uint8_t* mac) {
    if (mac[0] & 0x02) return false;
    if (!flockOuiBucketsReady) return false;
    const FlockOuiBucket& b = flockOuiBuckets[mac[0]];
    for (int i = b.start; i < b.start + b.count; i++) {
        if (mac[1] == FLOCK_OUI_TABLE[i].b[1] &&
            mac[2] == FLOCK_OUI_TABLE[i].b[2]) {
            if (FLOCK_OUI_TABLE[i].ext && !g_flockExtendedOui) continue;
            return true;
        }
    }
    return false;
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
