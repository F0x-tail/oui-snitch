// SPDX-License-Identifier: MIT
// Host tests for src/exposure.h: `pio test -e native`.
#include <unity.h>
#include <string.h>
#include "exposure.h"

// A probe request: header, then SSID element, rates, and [extra] elements
// that give each simulated phone its own layout.
struct Probe {
    uint8_t b[128];
    int n;
    Probe(uint8_t addr0, const char* ssid, uint8_t extra) : n(24) {
        memset(b, 0, sizeof(b));
        b[0] = 0x40;
        memset(&b[4], 0xff, 6);
        b[10] = addr0; b[11] = 0x11; b[15] = extra;
        memset(&b[16], 0xff, 6);
        uint8_t sl = (uint8_t)strlen(ssid);
        b[n++] = 0; b[n++] = sl; memcpy(&b[n], ssid, sl); n += sl;
        b[n++] = 1; b[n++] = 4; n += 4;                       // supported rates
        b[n++] = 3; b[n++] = 1; b[n++] = 6;                   // DS parameter set
        for (uint8_t k = 0; k < extra; k++) { b[n++] = 45; b[n++] = (uint8_t)(10 + k); n += 10 + k; }
    }
};

void test_layout_ignores_ssid_and_channel(void) {
    Probe a(0x02, "home", 1), b(0x06, "", 1), c(0x02, "home", 2);
    b.b[34] = 11;                                             // its DS parameter: channel 11
    TEST_ASSERT_EQUAL_UINT32(expoLayout(a.b, a.n), expoLayout(b.b, b.n));
    TEST_ASSERT_NOT_EQUAL(expoLayout(a.b, a.n), expoLayout(c.b, c.n));
}

void test_spiking_phone_is_found_with_its_ssids(void) {
    static ExpoState s;
    expoStart(&s);
    // Baseline: a neighbour's phone probing steadily, ours quiet.
    for (int i = 0; i < 6; i++) { Probe p(0x02, "", 3); expoObserve(&s, p.b, p.n); }
    s.phase = EXPO_WATCH;
    // Watch: the neighbour carries on at the same rate (15/6 x 6 = 15) ...
    for (int i = 0; i < 15; i++) { Probe p(0x02, "", 3); expoObserve(&s, p.b, p.n); }
    // ... and ours turns Wi-Fi on: a burst, naming a hidden home network.
    for (int i = 0; i < 8; i++) {
        Probe p(0x06, i % 2 ? "MyHiddenNet" : "", 1);
        expoObserve(&s, p.b, p.n);
    }
    ExpoResult r = expoFinish(&s, 6000, 15000);
    TEST_ASSERT_TRUE(r.found);
    TEST_ASSERT_EQUAL(8, r.probes);
    TEST_ASSERT_TRUE(r.randomAddr);
    TEST_ASSERT_FALSE(r.globalAddr);
    TEST_ASSERT_EQUAL(1, r.nSsid);                            // repeats folded
    TEST_ASSERT_EQUAL(11, r.ssidLen[0]);
    TEST_ASSERT_EQUAL_MEMORY("MyHiddenNet", r.ssid[0], 11);
    TEST_ASSERT_EQUAL(EXPO_DONE, s.phase);
    TEST_ASSERT_EQUAL_UINT32(0, s.g[0].layout);               // nothing kept
}

void test_no_clear_spike(void) {
    static ExpoState s;
    expoStart(&s);
    for (int i = 0; i < 4; i++) { Probe p(0x02, "", 1); expoObserve(&s, p.b, p.n); }
    s.phase = EXPO_WATCH;
    for (int i = 0; i < 11; i++) { Probe p(0x02, "", 1); expoObserve(&s, p.b, p.n); }
    ExpoResult r = expoFinish(&s, 6000, 15000);               // 4 x 2.5 = 10 expected
    TEST_ASSERT_FALSE(r.found);
}

void test_encode(void) {
    ExpoResult r;
    memset(&r, 0, sizeof(r));
    r.found = true; r.probes = 300; r.globalAddr = true; r.nSsid = 2;
    r.ssidLen[0] = 2; memcpy(r.ssid[0], "ab", 2);
    r.ssidLen[1] = 3; memcpy(r.ssid[1], "xyz", 3);
    uint8_t out[64];
    int n = expoEncode(&r, out, sizeof(out));
    const uint8_t want[] = {1, 300 & 0xFF, 300 >> 8, 0x02, 2, 2, 'a', 'b', 3, 'x', 'y', 'z'};
    TEST_ASSERT_EQUAL(sizeof(want), n);
    TEST_ASSERT_EQUAL_MEMORY(want, out, sizeof(want));
    // Too little room: the SSIDs that fit, with the count to match.
    n = expoEncode(&r, out, 8);
    TEST_ASSERT_EQUAL(8, n);
    TEST_ASSERT_EQUAL(1, out[4]);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_layout_ignores_ssid_and_channel);
    RUN_TEST(test_spiking_phone_is_found_with_its_ssids);
    RUN_TEST(test_no_clear_spike);
    RUN_TEST(test_encode);
    return UNITY_END();
}
