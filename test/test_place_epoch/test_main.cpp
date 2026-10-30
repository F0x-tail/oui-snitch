// SPDX-License-Identifier: MIT
// Host tests for src/place_epoch.h: `pio test -e native`.
#include <unity.h>
#include <string.h>
#include "place_epoch.h"

// One window's worth of a scene: [n] devices, [apple] of them Apple, the
// rest split between [other] company IDs; [seed] keeps scenes' addresses apart.
static bool scene(PlaceState* s, uint32_t t, int n, int apple, const uint16_t* other, int nOther,
                  uint8_t seed) {
    bool moved = false;
    for (int i = 0; i < n; i++) {
        uint8_t mac[6] = {seed, (uint8_t)i, (uint8_t)(i >> 8), 0x10, 0x20, 0x30};
        uint16_t cid = i < apple ? 0x004C : other[i % nOther];
        moved |= placeObserve(s, mac, cid, t + i);
    }
    return moved;
}

static const uint16_t HOME[] = {0x0006, 0x0075};                         // Microsoft, Samsung
static const uint16_t TRAIN[] = {0x00E0, 0x0157, 0x038F, PLACE_NO_MFG};  // a different mix

void test_same_place_stays_one_place(void) {
    static PlaceState s; placeInit(&s, 0);
    for (uint32_t k = 0; k < 20; k++)                         // 40 minutes at home
        TEST_ASSERT_FALSE(scene(&s, k * PLACE_WIN_MS, 12, 4, HOME, 2, 1));
    TEST_ASSERT_EQUAL(1, s.epoch);
}

void test_moving_starts_a_new_place(void) {
    static PlaceState s; placeInit(&s, 0);
    uint32_t t = 0;
    for (int k = 0; k < 6; k++, t += PLACE_WIN_MS) scene(&s, t, 12, 4, HOME, 2, 1);
    bool moved = false;
    for (int k = 0; k < 3; k++, t += PLACE_WIN_MS) moved |= scene(&s, t, 40, 30, TRAIN, 4, 2);
    TEST_ASSERT_TRUE(moved);                                  // reported by the call that rolled
    TEST_ASSERT_EQUAL(2, s.epoch);
}

void test_no_new_place_within_ten_minutes(void) {
    static PlaceState s; placeInit(&s, 0);
    uint32_t t = 0;
    scene(&s, t, 12, 4, HOME, 2, 1); t += PLACE_WIN_MS;       // home for one window
    scene(&s, t, 40, 30, TRAIN, 4, 2); t += PLACE_WIN_MS;     // then the train at 2 min
    scene(&s, t, 40, 30, TRAIN, 4, 2);
    TEST_ASSERT_EQUAL(1, s.epoch);
}

void test_slow_change_is_not_a_move(void) {
    static PlaceState s; placeInit(&s, 0);
    uint32_t t = 0;
    for (int n = 10; n <= 30; n += 2, t += PLACE_WIN_MS)      // a café filling up
        scene(&s, t, n, n / 3, HOME, 2, 1);
    TEST_ASSERT_EQUAL(1, s.epoch);
}

void test_quiet_windows_are_ignored(void) {
    static PlaceState s; placeInit(&s, 0);
    uint32_t t = 0;
    for (int k = 0; k < 6; k++, t += PLACE_WIN_MS) scene(&s, t, 12, 4, HOME, 2, 1);
    for (int k = 0; k < 10; k++, t += PLACE_WIN_MS) scene(&s, t, 2, 0, TRAIN, 4, 3);
    TEST_ASSERT_EQUAL(1, s.epoch);
}

void test_a_device_counts_once_per_window(void) {
    static PlaceState s; placeInit(&s, 0);
    uint8_t mac[6] = {1, 2, 3, 4, 5, 6};
    for (int i = 0; i < 50; i++) placeObserve(&s, mac, 0x004C, i);
    TEST_ASSERT_EQUAL(1, s.w.pop);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_same_place_stays_one_place);
    RUN_TEST(test_moving_starts_a_new_place);
    RUN_TEST(test_no_new_place_within_ten_minutes);
    RUN_TEST(test_slow_change_is_not_a_move);
    RUN_TEST(test_quiet_windows_are_ignored);
    RUN_TEST(test_a_device_counts_once_per_window);
    return UNITY_END();
}
