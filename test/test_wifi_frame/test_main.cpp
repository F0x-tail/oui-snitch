// SPDX-License-Identifier: MIT
// Host tests for src/wifi_frame.h: `pio test -e native`.
#include <unity.h>
#include <string.h>
#include "wifi_frame.h"

// A beacon: 24-byte header, 12-byte fixed body, then tagged elements.
struct Frame {
    uint8_t b[256];
    int n;
    Frame() : n(36) { memset(b, 0, sizeof(b)); }
    Frame& tag(uint8_t id, const uint8_t* body, uint8_t len) {
        b[n++] = id; b[n++] = len; memcpy(&b[n], body, len); n += len; return *this;
    }
};

static Frame rsnBeacon(const uint8_t* akms, int nAkm, const uint8_t* pw, int nPw, uint16_t caps) {
    uint8_t body[64]; int i = 0;
    body[i++] = 1; body[i++] = 0;                                  // version
    body[i++] = 0; body[i++] = 0x0F; body[i++] = 0xAC; body[i++] = 4;  // group CCMP
    body[i++] = (uint8_t)nPw; body[i++] = 0;
    for (int k = 0; k < nPw; k++) { body[i++] = 0; body[i++] = 0x0F; body[i++] = 0xAC; body[i++] = pw[k]; }
    body[i++] = (uint8_t)nAkm; body[i++] = 0;
    for (int k = 0; k < nAkm; k++) { body[i++] = 0; body[i++] = 0x0F; body[i++] = 0xAC; body[i++] = akms[k]; }
    body[i++] = caps & 0xFF; body[i++] = caps >> 8;
    Frame f; f.tag(48, body, (uint8_t)i); return f;
}

static void test_fcs_is_not_frame_data(void) {
    TEST_ASSERT_EQUAL(96, wifiFrameLen(100));
    TEST_ASSERT_EQUAL(0, wifiFrameLen(3));
}

static void test_akm_classification(void) {
    const uint8_t ccmp[] = {4};
    struct { uint8_t akms[2]; int n; uint8_t want; } cases[] = {
        {{2}, 1, 3}, {{8}, 1, 6}, {{2, 8}, 2, 7}, {{24}, 1, 6},
        {{18}, 1, 8}, {{1}, 1, 5}, {{12}, 1, 9}, {{6}, 1, 3},
    };
    for (auto& c : cases) {
        Frame f = rsnBeacon(c.akms, c.n, ccmp, 1, 0);
        TEST_ASSERT_EQUAL_UINT8(c.want, parseAuthFromFrame(f.b, f.n));
    }
}

static void test_vendor_akm_ignored(void) {
    // A vendor AKM numbered 8 is not SAE.
    uint8_t body[] = {1,0, 0,0x0F,0xAC,4, 1,0, 0,0x0F,0xAC,4, 1,0, 0x00,0x40,0x96,8};
    Frame f; f.tag(48, body, sizeof(body));
    TEST_ASSERT_EQUAL_UINT8(3, parseAuthFromFrame(f.b, f.n));
}

static void test_open_and_wep(void) {
    Frame f;
    TEST_ASSERT_EQUAL_UINT8(0, parseAuthFromFrame(f.b, f.n));
    f.b[34] = 0x10;  // Privacy bit, no RSN
    TEST_ASSERT_EQUAL_UINT8(1, parseAuthFromFrame(f.b, f.n));
}

static void test_ap_channel(void) {
    const uint8_t ds[] = {6};
    Frame f; f.tag(3, ds, 1);
    TEST_ASSERT_EQUAL_UINT8(6, apChannelFromFrame(f.b, f.n, 5));
    uint8_t ht[22] = {44};
    Frame g; g.tag(61, ht, sizeof(ht));
    TEST_ASSERT_EQUAL_UINT8(44, apChannelFromFrame(g.b, g.n, 40));
    Frame h;
    TEST_ASSERT_EQUAL_UINT8(11, apChannelFromFrame(h.b, h.n, 11));
}

static void test_ciphers_and_ibss(void) {
    const uint8_t akm[] = {2};
    const uint8_t pw[] = {4, 2};
    Frame f = rsnBeacon(akm, 1, pw, 2, 0);
    uint8_t caps = wifiCapsFromFrame(f.b, f.n);
    TEST_ASSERT_TRUE(caps & WIFI_CAPS_VALID);
    TEST_ASSERT_TRUE(caps & WIFI_CAPS_RSN_CCMP);
    TEST_ASSERT_TRUE(caps & WIFI_CAPS_RSN_TKIP);
    TEST_ASSERT_FALSE(caps & WIFI_CAPS_IBSS);
    f.b[34] = 0x02;
    TEST_ASSERT_TRUE(wifiCapsFromFrame(f.b, f.n) & WIFI_CAPS_IBSS);
}

static void test_wpa1_ciphers(void) {
    uint8_t wpa[] = {0x00,0x50,0xF2,0x01, 1,0, 0x00,0x50,0xF2,2, 1,0, 0x00,0x50,0xF2,2, 1,0, 0x00,0x50,0xF2,2};
    Frame f; f.tag(221, wpa, sizeof(wpa));
    uint8_t caps = wifiCapsFromFrame(f.b, f.n);
    TEST_ASSERT_TRUE(caps & WIFI_CAPS_WPA_TKIP);
    TEST_ASSERT_FALSE(caps & WIFI_CAPS_RSN_TKIP);
}

static void test_rcois(void) {
    // 2 ANQP OIs; OI#1 len 5, OI#2 len 3; then OI#3 of 3 bytes.
    uint8_t rc[] = {2, 0x35, 0x5A,0x03,0xBA,0x00,0x00, 0x00,0x1B,0xC5, 0xAA,0xBB,0xCC};
    Frame f; f.tag(111, rc, sizeof(rc));
    uint8_t out[15];
    uint8_t n = wifiRcoisFromFrame(f.b, f.n, out, sizeof(out));
    TEST_ASSERT_EQUAL_UINT8(14, n);
    TEST_ASSERT_EQUAL_UINT8(5, out[0]);
    TEST_ASSERT_EQUAL_UINT8(0x5A, out[1]);
    TEST_ASSERT_EQUAL_UINT8(3, out[6]);
    TEST_ASSERT_EQUAL_UINT8(3, out[10]);
    // A buffer too small keeps only the OIs that fit whole.
    TEST_ASSERT_EQUAL_UINT8(6, wifiRcoisFromFrame(f.b, f.n, out, 9));
}

static void test_pmf_required(void) {
    const uint8_t akm[] = {8};
    const uint8_t pw[] = {4};
    Frame f = rsnBeacon(akm, 1, pw, 1, 0x00C0);
    TEST_ASSERT_TRUE(wifiRsnCapabilities(f.b, f.n) & WIFI_RSN_CAP_MFPR);
    Frame g = rsnBeacon(akm, 1, pw, 1, 0x0080);
    TEST_ASSERT_FALSE(wifiRsnCapabilities(g.b, g.n) & WIFI_RSN_CAP_MFPR);
    Frame h;
    TEST_ASSERT_EQUAL(-1, wifiRsnCapabilities(h.b, h.n));
}

static void test_truncated_element_is_safe(void) {
    Frame f;
    f.b[f.n++] = 48; f.b[f.n++] = 40;   // claims 40 bytes, frame ends here
    TEST_ASSERT_EQUAL_UINT8(0, parseAuthFromFrame(f.b, f.n));
    TEST_ASSERT_EQUAL(-1, wifiRsnCapabilities(f.b, f.n));
    uint8_t out[15];
    TEST_ASSERT_EQUAL_UINT8(0, wifiRcoisFromFrame(f.b, f.n, out, sizeof(out)));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_fcs_is_not_frame_data);
    RUN_TEST(test_akm_classification);
    RUN_TEST(test_vendor_akm_ignored);
    RUN_TEST(test_open_and_wep);
    RUN_TEST(test_ap_channel);
    RUN_TEST(test_ciphers_and_ibss);
    RUN_TEST(test_wpa1_ciphers);
    RUN_TEST(test_rcois);
    RUN_TEST(test_pmf_required);
    RUN_TEST(test_truncated_element_is_safe);
    return UNITY_END();
}
