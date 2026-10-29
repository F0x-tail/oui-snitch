// SPDX-License-Identifier: MIT
#pragma once
// Pure 802.11 frame parsing: no ESP-IDF, no state, so every rule here can be
// unit tested on a PC (test/native). Frames are management frames whose body
// starts at byte 24; tagged elements start at 36 for beacons and probe
// responses.
#include <stdint.h>
#include <stddef.h>

#ifndef IRAM_ATTR
#define IRAM_ATTR
#endif

// Bytes of frame to parse, given the radio's sig_len. ESP-IDF reports
// sig_len *including* the 4-byte FCS (esp_wifi_types.h: "length of packet
// including Frame Check Sequence"); walked as data, the checksum can read as
// one more tagged element.
static inline int wifiFrameLen(int sigLen) { return sigLen > 4 ? sigLen - 4 : 0; }

// AKM suite numbers under the IEEE OUI 00-0F-AC, as hostap's
// src/common/wpa_common.h names them (IEEE 802.11-2020 Table 9-151).
// Personal: PSK 2, FT-PSK 4, PSK-SHA256 6, FT-PSK-SHA384 19, PSK-SHA384 20.
// SAE (WPA3 personal): 8, FT 9, SAE-EXT-KEY 24, FT-SAE-EXT-KEY 25.
// Enterprise: 1, 3, 5, 22, 23; Suite B (WPA3 enterprise) 11, 12, 13.
// OWE (Enhanced Open): 18.
static inline bool akmIsPsk(uint8_t t)  { return t == 2 || t == 4 || t == 6 || t == 19 || t == 20; }
static inline bool akmIsSae(uint8_t t)  { return t == 8 || t == 9 || t == 24 || t == 25; }
static inline bool akmIsEap(uint8_t t)  { return t == 1 || t == 3 || t == 5 || t == 22 || t == 23; }
static inline bool akmIsSuiteB(uint8_t t) { return t == 11 || t == 12 || t == 13; }

// Returns the auth_mode codes documented on DetectionEvent.ext.wardrive.
static inline uint8_t IRAM_ATTR parseAuthFromFrame(const uint8_t* p, int len) {
    int offset = 36;
    bool hasRSN = false, hasWPA = false;
    bool psk = false, sae = false, eap = false, suiteB = false, owe = false;

    while (offset + 2 <= len) {
        uint8_t tagId = p[offset];
        uint8_t tagLen = p[offset + 1];
        if (offset + 2 + tagLen > len) break;

        if (tagId == 48 && tagLen >= 2) {
            // RSN IE: version[2] group[4] pairwise_count[2] pairwise[n*4]
            //         akm_count[2] akm[n*4]
            hasRSN = true;
            int rsnOff = offset + 2 + 2;
            int rsnEnd = offset + 2 + tagLen;
            if (rsnOff + 4 > rsnEnd) goto next_tag;
            rsnOff += 4;
            if (rsnOff + 2 > rsnEnd) goto next_tag;
            uint16_t pairCount = p[rsnOff] | (p[rsnOff + 1] << 8);
            rsnOff += 2 + pairCount * 4;
            if (rsnOff + 2 > rsnEnd) goto next_tag;
            uint16_t akmCount = p[rsnOff] | (p[rsnOff + 1] << 8);
            rsnOff += 2;
            for (uint16_t i = 0; i < akmCount && rsnOff + 4 <= rsnEnd; i++, rsnOff += 4) {
                // Vendor AKMs carry their own OUI; their numbers mean nothing here.
                if (p[rsnOff] != 0x00 || p[rsnOff + 1] != 0x0F || p[rsnOff + 2] != 0xAC) continue;
                uint8_t t = p[rsnOff + 3];
                psk |= akmIsPsk(t);
                sae |= akmIsSae(t);
                eap |= akmIsEap(t);
                suiteB |= akmIsSuiteB(t);
                owe |= (t == 18);
            }
        }

        if (tagId == 221 && tagLen >= 4) {     // Vendor-specific (WPA1)
            if (p[offset+2]==0x00 && p[offset+3]==0x50 &&
                p[offset+4]==0xF2 && p[offset+5]==0x01) {
                hasWPA = true;
            }
        }

        next_tag:
        offset += 2 + tagLen;
    }

    if (suiteB)             return 9;  // WPA3_ENT
    if (sae && psk)         return 7;  // WPA2_WPA3 (transition)
    if (sae)                return 6;  // WPA3
    if (owe)                return 8;  // OWE
    if (eap)                return 5;  // WPA2_ENT
    if (hasRSN && hasWPA)   return 4;  // WPA_WPA2
    if (hasRSN)             return 3;  // WPA2
    if (hasWPA)             return 2;  // WPA
    if (len >= 36 && (p[34] & 0x10)) return 1;  // WEP (Privacy bit set, no RSN/WPA)
    return 0;                           // Open
}

// The channel the AP says it is on: DS Parameter Set (tag 3), else the
// primary channel in HT Operation (tag 61). The radio's own channel is only a
// fallback. On 2.4 GHz a beacon is routinely heard one or two channels away
// from where it was sent, and recording the tuned channel put networks on
// the wrong channel and frequency in the WiGLE export.
static inline uint8_t IRAM_ATTR apChannelFromFrame(const uint8_t* p, int len, uint8_t rxChannel) {
    uint8_t ht = 0;
    for (int o = 36; o + 2 <= len;) {
        uint8_t id = p[o], tl = p[o + 1];
        if (o + 2 + tl > len) break;
        if (id == 3 && tl >= 1 && p[o + 2] != 0) return p[o + 2];
        if (id == 61 && tl >= 1 && p[o + 2] != 0) ht = p[o + 2];
        o += 2 + tl;
    }
    return ht ? ht : rxChannel;
}


// Pairwise ciphers and BSS type, packed for DetectionEvent.ext.wardrive.wifi_caps
// so the export can write AuthMode with its cipher segment, as Android does
// ("[WPA2-PSK-CCMP][RSN-PSK-CCMP][ESS]"). Cipher suite numbers per hostap's
// wpa_common.h: under 00-0F-AC (RSN) 2 TKIP, 4 CCMP-128, 9 GCMP-256; under
// 00-50-F2 (the WPA1 element) 2 TKIP, 4 CCMP.
#define WIFI_CAPS_RSN_CCMP    0x01
#define WIFI_CAPS_RSN_TKIP    0x02
#define WIFI_CAPS_RSN_GCMP256 0x04
#define WIFI_CAPS_WPA_TKIP    0x08
#define WIFI_CAPS_WPA_CCMP    0x10
#define WIFI_CAPS_IBSS        0x20
#define WIFI_CAPS_VALID       0x80  // set by firmware that parses these at all

static inline uint8_t IRAM_ATTR wifiPairwiseBits(const uint8_t* body, int bodyLen,
                                                 uint8_t o0, uint8_t o1, uint8_t o2,
                                                 bool rsn) {
    // version[2] group[4] pairwise_count[2] pairwise[n*4]
    if (bodyLen < 8) return 0;
    uint16_t n = body[6] | (body[7] << 8);
    uint8_t bits = 0;
    for (int i = 0, o = 8; i < n && o + 4 <= bodyLen; i++, o += 4) {
        if (body[o] != o0 || body[o + 1] != o1 || body[o + 2] != o2) continue;
        uint8_t t = body[o + 3];
        if (rsn) {
            if (t == 4) bits |= WIFI_CAPS_RSN_CCMP;
            else if (t == 2) bits |= WIFI_CAPS_RSN_TKIP;
            else if (t == 9) bits |= WIFI_CAPS_RSN_GCMP256;
        } else {
            if (t == 4) bits |= WIFI_CAPS_WPA_CCMP;
            else if (t == 2) bits |= WIFI_CAPS_WPA_TKIP;
        }
    }
    return bits;
}

static inline uint8_t IRAM_ATTR wifiCapsFromFrame(const uint8_t* p, int len) {
    uint8_t caps = WIFI_CAPS_VALID;
    // Capability Information, bit 1: IBSS (ad hoc) rather than ESS.
    if (len >= 36 && (p[34] & 0x02)) caps |= WIFI_CAPS_IBSS;
    for (int o = 36; o + 2 <= len;) {
        uint8_t id = p[o], tl = p[o + 1];
        if (o + 2 + tl > len) break;
        const uint8_t* b = &p[o + 2];
        if (id == 48) caps |= wifiPairwiseBits(b, tl, 0x00, 0x0F, 0xAC, true);
        if (id == 221 && tl >= 4 && b[0] == 0x00 && b[1] == 0x50 && b[2] == 0xF2 && b[3] == 0x01)
            caps |= wifiPairwiseBits(b + 4, tl - 4, 0x00, 0x50, 0xF2, false);
        o += 2 + tl;
    }
    return caps;
}

// Roaming Consortium OIs (element 111, Passpoint), for WiGLE's RCOIs column.
// Element body: number of ANQP OIs[1], OI#1/OI#2 lengths[1] (low/high
// nibble), OI#1, OI#2, then OI#3 taking whatever remains. Written to [out] as
// len[1] oi[len] pairs; stops at the first OI that does not fit. Returns the
// bytes written.
static inline uint8_t IRAM_ATTR wifiRcoisFromFrame(const uint8_t* p, int len,
                                                   uint8_t* out, uint8_t cap) {
    for (int o = 36; o + 2 <= len;) {
        uint8_t id = p[o], tl = p[o + 1];
        if (o + 2 + tl > len) break;
        if (id == 111 && tl >= 2) {
            const uint8_t* b = &p[o + 2];
            uint8_t l1 = b[1] & 0x0F, l2 = b[1] >> 4;
            int rest = tl - 2 - l1 - l2;
            if (rest < 0) return 0;
            uint8_t lens[3] = {l1, l2, (uint8_t)rest};
            const uint8_t* oi = b + 2;
            uint8_t w = 0;
            for (int k = 0; k < 3; k++) {
                uint8_t l = lens[k];
                if (l == 0) continue;
                if (l < 3 || l > 15 || w + 1 + l > cap) break;
                out[w++] = l;
                for (uint8_t j = 0; j < l; j++) out[w++] = oi[j];
                oi += l;
            }
            return w;
        }
        o += 2 + tl;
    }
    return 0;
}
