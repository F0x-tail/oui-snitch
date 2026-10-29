// SPDX-License-Identifier: MIT
// Host tests for the generated Flock prefix table: `pio test -e native`.
#include <unity.h>
#include "engines/flock_oui_table.h"

static int find(uint8_t a, uint8_t b, uint8_t c) {
    for (int i = 0; i < FLOCK_OUI_COUNT; i++) {
        const FlockOui& o = FLOCK_OUI_TABLE[i];
        if (o.b[0] == a && o.b[1] == b && o.b[2] == c) return o.tier;
    }
    return 0;
}

static void test_flock_own_prefix_is_vendor_tier(void) {
    TEST_ASSERT_EQUAL(FLOCK_OUI_VENDOR, find(0xB4, 0x1E, 0x52));
}

static void test_consumer_prefixes_are_gone(void) {
    TEST_ASSERT_EQUAL(0, find(0x00, 0x23, 0x6C));  // Apple
    TEST_ASSERT_EQUAL(0, find(0x48, 0x27, 0xEA));  // Samsung
    TEST_ASSERT_EQUAL(0, find(0x1C, 0xB7, 0x2C));  // ASUS
    TEST_ASSERT_EQUAL(0, find(0x00, 0x18, 0x0A));  // Cisco Meraki
}

static void test_no_locally_administered_prefix(void) {
    for (int i = 0; i < FLOCK_OUI_COUNT; i++)
        TEST_ASSERT_EQUAL_HEX8(0, FLOCK_OUI_TABLE[i].b[0] & 0x02);
}

// The matcher's first-byte buckets assume entries sharing a byte are adjacent.
static void test_sorted_so_buckets_are_contiguous(void) {
    for (int i = 1; i < FLOCK_OUI_COUNT; i++)
        TEST_ASSERT_TRUE(FLOCK_OUI_TABLE[i - 1].b[0] <= FLOCK_OUI_TABLE[i].b[0]);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_flock_own_prefix_is_vendor_tier);
    RUN_TEST(test_consumer_prefixes_are_gone);
    RUN_TEST(test_no_locally_administered_prefix);
    RUN_TEST(test_sorted_so_buckets_are_contiguous);
    return UNITY_END();
}
