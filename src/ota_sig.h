// SPDX-License-Identifier: MIT
// Signature check for over-the-air updates, and the trial run that lets a bad
// update roll back. Format: ota_sig_format.h.
#ifndef OTA_SIG_H
#define OTA_SIG_H

#include <stdint.h>
#include <esp_partition.h>

enum OtaSigResult : uint8_t {
    OTA_SIG_OK = 0,
    OTA_SIG_UNSIGNED,     // no trailer: an unsigned build
    OTA_SIG_WRONG_KEY,    // signed, but not with the key this board trusts
    OTA_SIG_BAD,          // tampered, or signed for another role / chip
    OTA_SIG_IO,           // could not read the partition
};

// This board's signing target, e.g. "node-esp32s3".
const char* otaSigTarget(void);

// Checks a signed update of `total` bytes already written to `part`. Call it
// before esp_ota_end / esp_ota_set_boot_partition; on anything but OTA_SIG_OK
// the image must not be booted.
OtaSigResult otaSigVerifyPartition(const esp_partition_t* part, uint32_t total);

// Same, against an explicit key and target (on-target tests).
OtaSigResult otaSigVerifyPartitionWith(const esp_partition_t* part, uint32_t total,
                                       const uint8_t pub[65], const char* target);

const char* otaSigResultName(OtaSigResult r);

// Trial run: a freshly updated image stays pending until it has run
// OTA_TRIAL_MS, or the app confirms it. If it crashes or loses power first,
// the bootloader goes back to the previous image. Call from loop().
void otaTrialTick(void);
bool otaTrialConfirm(void);   // mark the running image good now

#endif
