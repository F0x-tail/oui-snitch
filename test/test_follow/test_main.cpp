// SPDX-License-Identifier: MIT
// Host tests for src/follow.h: `pio test -e native`.
#include <unity.h>
#include <string.h>
#include "follow.h"

static void mac(uint8_t* m, uint8_t a, uint8_t b) { m[0] = a; m[1] = b; m[2] = 3; m[3] = 4; m[4] = 5; m[5] = 6; }

void test_fixed_addresses(void) {
    uint8_t m[6];
    mac(m, 0x00, 1); TEST_ASSERT_TRUE(followFixedAddress(m, false));    // public
    mac(m, 0xC5, 1); TEST_ASSERT_TRUE(followFixedAddress(m, true));     // random static
    mac(m, 0x45, 1); TEST_ASSERT_FALSE(followFixedAddress(m, true));    // resolvable private
    mac(m, 0x05, 1); TEST_ASSERT_FALSE(followFixedAddress(m, true));    // non-resolvable
}

void test_reported_after_three_places_once(void) {
    static FollowTable t; memset(&t, 0, sizeof(t));
    uint8_t m[6]; mac(m, 0xC0, 1);
    uint32_t now = 0;
    for (int i = 0; i < 100; i++) TEST_ASSERT_EQUAL(0, followObserve(&t, m, 1, now += 1000));  // an hour at home
    TEST_ASSERT_EQUAL(0, followObserve(&t, m, 2, now += 1000));
    TEST_ASSERT_EQUAL(3, followObserve(&t, m, 3, now += 1000));
    TEST_ASSERT_EQUAL(0, followObserve(&t, m, 4, now += 1000));    // once
}

void test_back_and_forth_counts_each_move(void) {
    static FollowTable t; memset(&t, 0, sizeof(t));
    uint8_t m[6]; mac(m, 0xC0, 1);
    followObserve(&t, m, 1, 1000);
    followObserve(&t, m, 2, 2000);
    TEST_ASSERT_EQUAL(3, followObserve(&t, m, 1, 3000));           // home, out, home again
}

void test_crowds_do_not_evict_a_follower(void) {
    static FollowTable t; memset(&t, 0, sizeof(t));
    uint8_t f[6]; mac(f, 0xC0, 0xEE);
    followObserve(&t, f, 1, 1000);
    followObserve(&t, f, 2, 2000);                                 // two places: protected
    uint8_t m[6];
    for (int i = 0; i < 500; i++) { mac(m, 0xC1, (uint8_t)i); m[2] = (uint8_t)(i >> 8); followObserve(&t, m, 2, 3000 + i); }
    TEST_ASSERT_EQUAL(3, followObserve(&t, f, 3, 10000));
}

void test_stale_candidates_are_forgotten(void) {
    static FollowTable t; memset(&t, 0, sizeof(t));
    uint8_t m[6]; mac(m, 0xC0, 1);
    followObserve(&t, m, 1, 1000);
    followObserve(&t, m, 2, 2000);
    uint8_t places = 0;
    followObserve(&t, m, 3, 2000 + FOLLOW_STALE_MS + 1, &places);
    TEST_ASSERT_EQUAL(1, places);                                  // started over
}

void test_memory_counts_sessions(void) {
    static FollowMem mem; memset(&mem, 0, sizeof(mem));
    mem.salt = 0x1234;
    uint8_t m[6]; mac(m, 0xC0, 1);
    TEST_ASSERT_EQUAL(0, followMemNote(&mem, m, 1));               // one place: not kept
    TEST_ASSERT_EQUAL(0, followMemNote(&mem, m, 2));               // kept, session 1
    TEST_ASSERT_TRUE(mem.dirty);
    TEST_ASSERT_EQUAL(0, followMemNote(&mem, m, 3));               // same boot
    // Next power-up: what was saved comes back, this-boot marks do not.
    memset(mem.seenThisBoot, 0, sizeof(mem.seenThisBoot));
    TEST_ASSERT_EQUAL(2, followMemNote(&mem, m, 1));
    memset(mem.seenThisBoot, 0, sizeof(mem.seenThisBoot));
    TEST_ASSERT_EQUAL(3, followMemNote(&mem, m, 1));
}

void test_memory_keeps_no_address(void) {
    static FollowMem mem; memset(&mem, 0, sizeof(mem));
    mem.salt = 0xBEEF;
    uint8_t m[6]; mac(m, 0xC0, 1);
    followMemNote(&mem, m, 2);
    // Only a salted hash is stored; another salt gives another id.
    TEST_ASSERT_EQUAL_UINT32(followMemId(0xBEEF, m), mem.r[0].id);
    TEST_ASSERT_NOT_EQUAL(followMemId(0xBEEF, m), followMemId(0xBEF0, m));
}

void test_memory_replaces_the_weakest(void) {
    static FollowMem mem; memset(&mem, 0, sizeof(mem));
    uint8_t m[6];
    for (int i = 0; i < FOLLOW_MEM_SLOTS; i++) { mac(m, 0xC0, (uint8_t)i); followMemNote(&mem, m, 2); }
    mem.r[5].sessions = 0;                                         // pretend one is weakest
    mac(m, 0xC0, 0xAA);
    followMemNote(&mem, m, 2);
    TEST_ASSERT_EQUAL_UINT32(followMemId(0, m), mem.r[5].id);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_fixed_addresses);
    RUN_TEST(test_reported_after_three_places_once);
    RUN_TEST(test_back_and_forth_counts_each_move);
    RUN_TEST(test_crowds_do_not_evict_a_follower);
    RUN_TEST(test_stale_candidates_are_forgotten);
    RUN_TEST(test_memory_counts_sessions);
    RUN_TEST(test_memory_keeps_no_address);
    RUN_TEST(test_memory_replaces_the_weakest);
    return UNITY_END();
}
