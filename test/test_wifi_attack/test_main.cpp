// SPDX-License-Identifier: MIT
// Host tests for src/wifi_attack.h: `pio test -e native`.
#include <unity.h>
#include <string.h>
#include "wifi_attack.h"

static void mac(uint8_t* out, uint8_t a, uint8_t b, uint8_t c, uint8_t d) {
    out[0] = a; out[1] = b; out[2] = c; out[3] = 0x10; out[4] = 0x20; out[5] = d;
}

// Management header: fc, duration, addr1 (RA), addr2 (TA), addr3 (BSSID).
struct Mgmt {
    uint8_t b[128];
    int n;
    Mgmt(uint8_t fc, const uint8_t* ra, const uint8_t* ta, const uint8_t* bssid) : n(24) {
        memset(b, 0, sizeof(b));
        b[0] = fc;
        memcpy(&b[4], ra, 6); memcpy(&b[10], ta, 6); memcpy(&b[16], bssid, 6);
    }
    Mgmt& body(int bytes) { n += bytes; return *this; }
    Mgmt& tag(uint8_t id, uint8_t len) { b[n++] = id; b[n++] = len; n += len; return *this; }
};

static Mgmt join(uint8_t fc, const uint8_t* sta, const uint8_t* ap) { return Mgmt(fc, ap, sta, ap).body(6); }
static Mgmt beacon(const uint8_t* ap, bool csa) {
    static const uint8_t bc[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    Mgmt m(WFC_BEACON, bc, ap, ap);
    m.body(12).tag(0, 4);
    if (csa) m.tag(37, 3);
    return m;
}

void test_join_request_direction(void) {
    uint8_t ap[6], sta[6];
    mac(ap, 0x00, 0x11, 0x22, 1); mac(sta, 0x02, 0x00, 0x00, 9);
    Mgmt req = join(WFC_AUTH, sta, ap);
    Mgmt reply = Mgmt(WFC_AUTH, sta, ap, ap).body(6);
    TEST_ASSERT_TRUE(wifiIsJoinRequest(req.b, req.n));
    TEST_ASSERT_FALSE(wifiIsJoinRequest(reply.b, reply.n));
    Mgmt assoc = join(WFC_ASSOC_REQ, sta, ap), re = join(WFC_REASSOC_REQ, sta, ap);
    TEST_ASSERT_TRUE(wifiIsJoinRequest(assoc.b, assoc.n));
    TEST_ASSERT_TRUE(wifiIsJoinRequest(re.b, re.n));
    TEST_ASSERT_FALSE(wifiIsJoinRequest(beacon(ap, false).b, 40));
}

void test_flood_from_many_senders(void) {
    static JoinWatch w; memset(&w, 0, sizeof(w));
    uint8_t ap[6], sta[6], n = 0;
    mac(ap, 0x00, 0x11, 0x22, 1);
    int floods = 0;
    for (int i = 0; i < 40; i++) {
        mac(sta, 0x02, (uint8_t)i, (uint8_t)(i * 7), (uint8_t)(i * 13));
        Mgmt f = join(WFC_AUTH, sta, ap);
        if (joinObserve(&w, f.b, 1000 + i * 20, &n) == JOIN_FLOOD) floods++;
    }
    TEST_ASSERT_EQUAL(1, floods);                       // reported once, not per frame
    TEST_ASSERT_TRUE(n >= JOIN_FLOOD_SENDERS);
}

void test_few_clients_are_not_a_flood(void) {
    static JoinWatch w; memset(&w, 0, sizeof(w));
    uint8_t ap[6], sta[6], n = 0;
    mac(ap, 0x00, 0x11, 0x22, 1);
    for (int i = 0; i < 6; i++) {
        mac(sta, 0x02, (uint8_t)i, 0x33, (uint8_t)i);
        for (int rep = 0; rep < 4; rep++) {               // retries and assoc after auth
            Mgmt f = join(rep ? WFC_ASSOC_REQ : WFC_AUTH, sta, ap);
            TEST_ASSERT_EQUAL(JOIN_NONE, joinObserve(&w, f.b, 1000 + i * 100 + rep, &n));
        }
    }
}

void test_sweep_across_vendors(void) {
    static JoinWatch w; memset(&w, 0, sizeof(w));
    uint8_t ap[6], sta[6], n = 0;
    mac(sta, 0x02, 0xaa, 0xbb, 1);
    uint8_t v = JOIN_NONE;
    for (int i = 0; i < 10 && v == JOIN_NONE; i++) {
        mac(ap, 0x00, (uint8_t)(0x10 + i), (uint8_t)(0x40 + i), (uint8_t)i);   // a vendor each
        Mgmt f = join(WFC_AUTH, sta, ap);
        v = joinObserve(&w, f.b, 1000 + i * 3000, &n);
    }
    TEST_ASSERT_EQUAL(JOIN_SWEEP, v);
    TEST_ASSERT_TRUE(n >= JOIN_SWEEP_APS);
}

void test_roaming_within_one_network_is_not_a_sweep(void) {
    static JoinWatch w; memset(&w, 0, sizeof(w));
    uint8_t ap[6], sta[6], n = 0;
    mac(sta, 0x02, 0xaa, 0xbb, 1);
    for (int i = 0; i < 12; i++) {
        mac(ap, 0x00, 0x11, 0x22, (uint8_t)i);             // one vendor, many radios
        Mgmt f = join(WFC_REASSOC_REQ, sta, ap);
        TEST_ASSERT_EQUAL(JOIN_NONE, joinObserve(&w, f.b, 1000 + i * 2000, &n));
    }
}

void test_anonymous_reassociation(void) {
    static JoinWatch w; memset(&w, 0, sizeof(w));
    uint8_t ap[6], n = 0;
    static const uint8_t bc[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    mac(ap, 0x00, 0x11, 0x22, 1);
    Mgmt f = join(WFC_REASSOC_REQ, bc, ap);
    TEST_ASSERT_TRUE(wifiIsJoinRequest(f.b, f.n));
    TEST_ASSERT_EQUAL(JOIN_ANON, joinObserve(&w, f.b, 5000, &n));
    TEST_ASSERT_EQUAL(JOIN_NONE, joinObserve(&w, f.b, 5500, &n));   // one report
    TEST_ASSERT_TRUE(joinAnonRecent(&w, ap, 9000));
    TEST_ASSERT_FALSE(joinAnonRecent(&w, ap, 5500 + JOIN_ANON_RECENT_MS + 1));   // from the last one
    uint8_t other[6]; mac(other, 0x00, 0x11, 0x22, 2);
    TEST_ASSERT_FALSE(joinAnonRecent(&w, other, 9000));
}

void test_csa_element_and_action(void) {
    uint8_t ap[6], sta[6];
    mac(ap, 0x00, 0x11, 0x22, 1); mac(sta, 0x02, 0, 0, 9);
    Mgmt plain = beacon(ap, false), csa = beacon(ap, true);
    TEST_ASSERT_FALSE(wifiHasCsa(plain.b, plain.n));
    TEST_ASSERT_TRUE(wifiHasCsa(csa.b, csa.n));
    Mgmt act(WFC_ACTION, sta, ap, ap);
    act.b[24] = 0; act.b[25] = 4; act.n = 30;               // spectrum mgmt, channel switch
    TEST_ASSERT_TRUE(wifiHasCsa(act.b, act.n));
    act.b[24] = 3;                                           // block ack: not a switch
    TEST_ASSERT_FALSE(wifiHasCsa(act.b, act.n));
}

void test_forged_switch_beside_real_ap(void) {
    static CsaWatch w; memset(&w, 0, sizeof(w));
    uint8_t ap[6]; mac(ap, 0x00, 0x11, 0x22, 1);
    Mgmt plain = beacon(ap, false), csa = beacon(ap, true);
    TEST_ASSERT_EQUAL(CSA_NONE, csaObserve(&w, plain.b, plain.n, 6, 1000));
    TEST_ASSERT_EQUAL(CSA_SUSPECT, csaObserve(&w, csa.b, csa.n, 6, 1100));
    TEST_ASSERT_EQUAL(CSA_FORGED, csaObserve(&w, plain.b, plain.n, 6, 1200));
    TEST_ASSERT_EQUAL(CSA_NONE, csaObserve(&w, plain.b, plain.n, 6, 1300));   // once
}

void test_genuine_switch_is_not_forged(void) {
    static CsaWatch w; memset(&w, 0, sizeof(w));
    uint8_t ap[6]; mac(ap, 0x00, 0x11, 0x22, 1);
    Mgmt plain = beacon(ap, false), csa = beacon(ap, true);
    TEST_ASSERT_EQUAL(CSA_SUSPECT, csaObserve(&w, csa.b, csa.n, 6, 1000));
    TEST_ASSERT_EQUAL(CSA_NONE, csaObserve(&w, csa.b, csa.n, 6, 1100));
    // Moved: beacons now claim the new channel.
    TEST_ASSERT_EQUAL(CSA_NONE, csaObserve(&w, plain.b, plain.n, 11, 1500));
    // 5 GHz: radar moves are normal, a switch alone is not reported.
    uint8_t ap5[6]; mac(ap5, 0x00, 0x11, 0x22, 2);
    Mgmt csa5 = beacon(ap5, true);
    TEST_ASSERT_EQUAL(CSA_NONE, csaObserve(&w, csa5.b, csa5.n, 52, 2000));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_join_request_direction);
    RUN_TEST(test_flood_from_many_senders);
    RUN_TEST(test_few_clients_are_not_a_flood);
    RUN_TEST(test_sweep_across_vendors);
    RUN_TEST(test_roaming_within_one_network_is_not_a_sweep);
    RUN_TEST(test_anonymous_reassociation);
    RUN_TEST(test_csa_element_and_action);
    RUN_TEST(test_forged_switch_beside_real_ap);
    RUN_TEST(test_genuine_switch_is_not_forged);
    return UNITY_END();
}
