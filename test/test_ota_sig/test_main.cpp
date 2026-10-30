// SPDX-License-Identifier: MIT
// On-board test of the update signature check: `pio test -e ota_sig_test`.
// Writes a small signed test image into the inactive OTA slot, never the
// running one, and checks it the way the update receivers do. The key here is
// a throwaway test key, not the release key.
#include <Arduino.h>
#include <unity.h>
#include <esp_ota_ops.h>
#include "ota_sig.h"
#include "ota_sig_format.h"

static const uint8_t TEST_PUB[65] = {
    0x04, 0x9f, 0x70, 0xf4, 0xaa, 0x29, 0x9c, 0x9e, 0xca, 0xad, 0xf0, 0xdb, 0xa5, 0xc2, 0x6a, 0xef,
    0x10, 0xdd, 0xa7, 0xf4, 0x06, 0x44, 0x60, 0xf2, 0xff, 0x6a, 0x54, 0xcd, 0x80, 0x7c, 0xde, 0x3e,
    0xf5, 0x1b, 0x93, 0x1a, 0x75, 0xaf, 0x0f, 0x0b, 0x39, 0x87, 0xdd, 0x06, 0xf8, 0x9c, 0xde, 0xb5,
    0x35, 0x2a, 0x9e, 0xc5, 0x99, 0xc3, 0xe7, 0x62, 0xe1, 0x6e, 0x42, 0x8c, 0x9c, 0x1e, 0xab, 0xec,
    0xd4
};
static const uint8_t TEST_TRAILER[OTA_SIG_TRAILER_LEN] = {
    0x4f, 0x53, 0x4e, 0x53, 0x49, 0x47, 0x30, 0x31, 0x56, 0x5c, 0x35, 0x4c, 0x3e, 0x60, 0x50, 0xf8,
    0xd2, 0xa1, 0x4a, 0x8e, 0x2b, 0xea, 0x5d, 0xaa, 0x2d, 0x43, 0x08, 0xf6, 0xfb, 0x34, 0xcb, 0xf9,
    0x0a, 0xf1, 0xb7, 0xe9, 0x71, 0x44, 0xf5, 0xe6, 0xf2, 0x7d, 0x0f, 0x39, 0x9a, 0x3e, 0x4a, 0x92,
    0x58, 0x93, 0x1d, 0xd2, 0xec, 0xb4, 0x1f, 0xe0, 0x46, 0xe7, 0xd2, 0xac, 0x12, 0x35, 0xcb, 0xf0,
    0xdc, 0x5f, 0x9a, 0x45, 0x76, 0x7b, 0x5e, 0x34, 0x43, 0x72, 0x1d, 0x64
};
static const uint32_t IMAGE_LEN = 6000;

static uint8_t imageByte(uint32_t i) { return i == 0 ? 0xE9 : (uint8_t)((i * 7 + 3) & 0xFF); }

static const esp_partition_t* slot;

// Writes the test image to the inactive slot, flipping one byte if asked.
static uint32_t writeImage(bool withTrailer, int32_t flip = -1) {
    TEST_ASSERT_EQUAL(ESP_OK, esp_partition_erase_range(slot, 0, 8192));
    uint8_t buf[IMAGE_LEN + OTA_SIG_TRAILER_LEN];
    for (uint32_t i = 0; i < IMAGE_LEN; i++) buf[i] = imageByte(i);
    if (flip >= 0) buf[flip] ^= 0x01;
    uint32_t total = IMAGE_LEN;
    if (withTrailer) { memcpy(buf + IMAGE_LEN, TEST_TRAILER, OTA_SIG_TRAILER_LEN); total += OTA_SIG_TRAILER_LEN; }
    TEST_ASSERT_EQUAL(ESP_OK, esp_partition_write(slot, 0, buf, (total + 3) & ~3u));
    return total;
}

static void test_good_signature(void) {
    uint32_t n = writeImage(true);
    TEST_ASSERT_EQUAL(OTA_SIG_OK, otaSigVerifyPartitionWith(slot, n, TEST_PUB, "node-esp32s3"));
}

static void test_other_target_is_refused(void) {
    uint32_t n = writeImage(true);
    TEST_ASSERT_EQUAL(OTA_SIG_BAD, otaSigVerifyPartitionWith(slot, n, TEST_PUB, "manager-esp32s3"));
}

static void test_tampered_image_is_refused(void) {
    uint32_t n = writeImage(true, 4000);
    TEST_ASSERT_EQUAL(OTA_SIG_BAD, otaSigVerifyPartitionWith(slot, n, TEST_PUB, "node-esp32s3"));
}

static void test_unsigned_image_is_refused(void) {
    uint32_t n = writeImage(false);
    TEST_ASSERT_EQUAL(OTA_SIG_UNSIGNED, otaSigVerifyPartitionWith(slot, n, TEST_PUB, "node-esp32s3"));
}

static void test_release_key_refuses_test_signature(void) {
    uint32_t n = writeImage(true);
    TEST_ASSERT_EQUAL(OTA_SIG_WRONG_KEY, otaSigVerifyPartition(slot, n));
}

static void test_target_is_role_and_chip(void) {
    TEST_ASSERT_EQUAL_STRING("node-esp32s3", otaSigTarget());
}

void setup() {
    delay(2000);
    slot = esp_ota_get_next_update_partition(NULL);
    UNITY_BEGIN();
    RUN_TEST(test_target_is_role_and_chip);
    RUN_TEST(test_good_signature);
    RUN_TEST(test_other_target_is_refused);
    RUN_TEST(test_tampered_image_is_refused);
    RUN_TEST(test_unsigned_image_is_refused);
    RUN_TEST(test_release_key_refuses_test_signature);
    UNITY_END();
}

void loop() {}
