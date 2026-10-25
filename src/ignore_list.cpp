// SPDX-License-Identifier: MIT
#include "ignore_list.h"
#include <Arduino.h>
#include <Preferences.h>
#include <string.h>
#include <ctype.h>

struct IgnoreSlot {
    uint8_t type;
    uint8_t scope;
    uint8_t len;
    uint8_t value[IGNORE_MAX_VALUE];
};

static IgnoreSlot g_entries[IGNORE_MAX_ENTRIES];
static uint8_t g_count = 0;
static uint32_t g_version = 0;
static portMUX_TYPE g_mux = portMUX_INITIALIZER_UNLOCKED;
static IgnoreSlot g_tmp[IGNORE_MAX_ENTRIES];
static StaticSemaphore_t g_tmpLockBuf;
static SemaphoreHandle_t g_tmpLock = xSemaphoreCreateMutexStatic(&g_tmpLockBuf);

// NVS persistence. The list used to be WIPED here on every boot (p.clear()),
// so an ignored device came back after a power cycle — and on a standalone
// board, with no phone to re-push the list, it stayed back.
static const char* kIgnNs  = "ouispy-ign";
static const char* kIgnKey = "slots";

static void ignoreListSave(void) {
    IgnoreSlot snap[IGNORE_MAX_ENTRIES];
    uint8_t cnt;
    portENTER_CRITICAL(&g_mux);
    cnt = g_count;
    memcpy(snap, g_entries, sizeof(IgnoreSlot) * cnt);
    portEXIT_CRITICAL(&g_mux);

    Preferences p;
    if (!p.begin(kIgnNs, false)) return;
    if (cnt == 0) {
        p.remove(kIgnKey);
    } else {
        p.putBytes(kIgnKey, snap, sizeof(IgnoreSlot) * cnt);
    }
    p.end();
}

void ignoreListInit(void) {
    IgnoreSlot loaded[IGNORE_MAX_ENTRIES];
    uint8_t cnt = 0;

    Preferences p;
    if (p.begin(kIgnNs, true)) {
        size_t have = p.getBytesLength(kIgnKey);
        // Only accept a whole number of slots that fits the array; a short or
        // ragged blob means a format change, so start clean rather than
        // reinterpret someone else's bytes.
        if (have > 0 && have % sizeof(IgnoreSlot) == 0 &&
            have <= sizeof(IgnoreSlot) * IGNORE_MAX_ENTRIES) {
            if (p.getBytes(kIgnKey, loaded, have) == have) {
                cnt = (uint8_t)(have / sizeof(IgnoreSlot));
                // Reject any slot whose declared length is impossible.
                for (uint8_t i = 0; i < cnt; i++) {
                    if (loaded[i].len == 0 || loaded[i].len > IGNORE_MAX_VALUE) {
                        cnt = 0;
                        break;
                    }
                }
            }
        }
        p.end();
    }

    portENTER_CRITICAL(&g_mux);
    if (cnt > 0) memcpy(g_entries, loaded, sizeof(IgnoreSlot) * cnt);
    g_count = cnt;
    g_version++;
    portEXIT_CRITICAL(&g_mux);

    Serial.printf("[IGNORE] restored %u entries from NVS\n", cnt);
}

void ignoreListSet(const uint8_t* buf, size_t len) {
    if (!buf || len < 1) {
        portENTER_CRITICAL(&g_mux);
        g_count = 0;
        g_version++;
        portEXIT_CRITICAL(&g_mux);
        ignoreListSave();
        Serial.println("[IGNORE] list cleared");
        return;
    }
    xSemaphoreTake(g_tmpLock, portMAX_DELAY);
    IgnoreSlot* tmp = g_tmp;
    // Zero first: only vlen bytes of each value[] are written, and the
    // change-detection memcmp below compares whole slots. Stale tail bytes
    // from an earlier call would make an identical list look changed and
    // force a needless version bump / re-sync.
    memset(tmp, 0, sizeof(IgnoreSlot) * IGNORE_MAX_ENTRIES);
    uint8_t cnt = 0;
    size_t i = 0;
    uint8_t declared = buf[i++];
    while (i + 3 <= len && cnt < IGNORE_MAX_ENTRIES) {
        uint8_t type = buf[i++];
        uint8_t scope = buf[i++];
        uint8_t vlen = buf[i++];
        if (vlen == 0 || vlen > IGNORE_MAX_VALUE) break;
        if (i + vlen > len) break;
        tmp[cnt].type = type;
        tmp[cnt].scope = scope;
        tmp[cnt].len = vlen;
        memcpy(tmp[cnt].value, buf + i, vlen);
        i += vlen;
        cnt++;
    }
    bool same;
    portENTER_CRITICAL(&g_mux);
    same = (cnt == g_count) && (memcmp(g_entries, tmp, sizeof(IgnoreSlot) * cnt) == 0);
    if (!same) {
        memcpy(g_entries, tmp, sizeof(IgnoreSlot) * cnt);
        g_count = cnt;
        g_version++;
    }
    portEXIT_CRITICAL(&g_mux);
    xSemaphoreGive(g_tmpLock);
    if (same) return;
    ignoreListSave();
    Serial.printf("[IGNORE] list set: %u entries (declared %u, v%lu)\n",
                  cnt, declared, (unsigned long)g_version);
}

static bool ssidEq(const uint8_t* v, uint8_t vlen, const char* ssid) {
    if (!ssid) return false;
    size_t sl = strnlen(ssid, 32);
    if (sl != vlen) return false;
    return memcmp(v, ssid, vlen) == 0;
}

bool ignoreListMatch(const uint8_t mac[6], const char* ssid, bool isBle) {
    if (g_count == 0) return false;
    bool hit = false;
    portENTER_CRITICAL(&g_mux);
    for (uint8_t i = 0; i < g_count; i++) {
        const IgnoreSlot& e = g_entries[i];
        if (e.scope == IGNORE_SCOPE_WIFI && isBle) continue;
        if (e.scope == IGNORE_SCOPE_BLE && !isBle) continue;
        switch (e.type) {
            case IGNORE_TYPE_MAC:
                if (e.len == 6 && memcmp(e.value, mac, 6) == 0) { hit = true; }
                break;
            case IGNORE_TYPE_OUI:
                if (e.len == 3 && memcmp(e.value, mac, 3) == 0) { hit = true; }
                break;
            case IGNORE_TYPE_SSID:
                if (ssid && ssid[0] && ssidEq(e.value, e.len, ssid)) { hit = true; }
                break;
            default: break;
        }
        if (hit) break;
    }
    portEXIT_CRITICAL(&g_mux);
    return hit;
}

size_t ignoreListSerialize(uint8_t* out, size_t maxLen) {
    if (!out || maxLen < 1) return 0;
    size_t i = 0;
    portENTER_CRITICAL(&g_mux);
    out[i++] = g_count;
    for (uint8_t e = 0; e < g_count; e++) {
        if (i + 3 + g_entries[e].len > maxLen) break;
        out[i++] = g_entries[e].type;
        out[i++] = g_entries[e].scope;
        out[i++] = g_entries[e].len;
        memcpy(out + i, g_entries[e].value, g_entries[e].len);
        i += g_entries[e].len;
    }
    portEXIT_CRITICAL(&g_mux);
    return i;
}

uint8_t ignoreListCount(void) { return g_count; }
uint32_t ignoreListVersion(void) { return g_version; }
