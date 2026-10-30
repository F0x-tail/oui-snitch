// SPDX-License-Identifier: MIT
// Signed-update format, shared by the board and tools/sign_firmware.py.
// Pure: no ESP-IDF, so it builds in host tests.
//
// A signed update is the esptool app image with a trailer appended:
//
//   image | "OSNSIG01" | key id (4) | ECDSA P-256 signature r||s (64)
//
// The signature covers SHA-256(OTA_SIG_DOMAIN + target + "\n" + image), so an
// image signed for one role or chip is refused by another. The target is the
// role and chip, e.g. "node-esp32s3". Key id is the first 4 bytes of SHA-256
// over the 65-byte uncompressed public key; it only makes a wrong-key error
// readable, the signature is what is checked.
#pragma once
#include <stdint.h>
#include <string.h>

#define OTA_SIG_DOMAIN      "OUI-SNITCH-OTA1\n"
#define OTA_SIG_MAGIC       "OSNSIG01"
#define OTA_SIG_MAGIC_LEN   8
#define OTA_SIG_KEYID_LEN   4
#define OTA_SIG_RS_LEN      64
#define OTA_SIG_TRAILER_LEN (OTA_SIG_MAGIC_LEN + OTA_SIG_KEYID_LEN + OTA_SIG_RS_LEN)

// Image bytes in a signed file of `total` bytes, or 0 if it is too short to
// hold an image and a trailer.
static inline uint32_t otaSigImageLen(uint32_t total) {
    return total > OTA_SIG_TRAILER_LEN ? total - OTA_SIG_TRAILER_LEN : 0;
}

// Splits a trailer into key id and signature; false if the magic is missing,
// i.e. the file was never signed.
static inline bool otaSigParseTrailer(const uint8_t* t, const uint8_t** keyId,
                                      const uint8_t** rs) {
    if (memcmp(t, OTA_SIG_MAGIC, OTA_SIG_MAGIC_LEN) != 0) return false;
    *keyId = t + OTA_SIG_MAGIC_LEN;
    *rs = t + OTA_SIG_MAGIC_LEN + OTA_SIG_KEYID_LEN;
    return true;
}
