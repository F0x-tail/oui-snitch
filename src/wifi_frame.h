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

