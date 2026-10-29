// SPDX-License-Identifier: MIT
#include "wd_log.h"

#ifdef OUISPY_ROLE_MANAGER
// The manager has no GPS module of its own and does not wardrive offline.
void     wdLogInit(void) {}
bool     wdLogAppend(const DetectionEvent*) { return false; }
void     wdLogFlushIfDue(void) {}
uint32_t wdLogCount(void) { return 0; }
bool     wdLogFull(void) { return false; }
uint16_t wdLogReadBlock(uint32_t, WdLogRecord*, uint16_t) { return 0; }
void     wdLogClear(void) {}
#else

#include <LittleFS.h>
#include <string.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#define WDLOG_PATH       "/wdlog.bin"
// About 17,700 rows. The partition also holds the detection spool (~165 KB).
#define WDLOG_MAX_BYTES  (1024u * 1024u)
#define WDLOG_BUF_ROWS   64
#define WDLOG_FLUSH_MS   30000u
// A fix older than this no longer describes where the row was heard.
#define WDLOG_FIX_MAX_AGE_MS 3000u

extern volatile GpsData currentGps;
extern bool hwGpsActive(void);
extern bool hwGpsUtc(uint32_t* epochOut);

static WdLogRecord s_buf[WDLOG_BUF_ROWS];
static uint16_t s_bufN = 0;
static uint32_t s_onFlash = 0;
static uint32_t s_lastFlushMs = 0;
static bool s_ready = false;
static bool s_full = false;
static SemaphoreHandle_t s_mutex = nullptr;

static const uint32_t kMaxRows = WDLOG_MAX_BYTES / sizeof(WdLogRecord);

void wdLogInit(void) {
    if (!s_mutex) s_mutex = xSemaphoreCreateMutex();
    if (s_ready) return;
    if (!LittleFS.begin(true)) {
        Serial.println("[WDLOG] LittleFS unavailable — offline wardrive off");
        return;
    }
    File f = LittleFS.open(WDLOG_PATH, "r");
    if (f) {
        s_onFlash = f.size() / sizeof(WdLogRecord);
        f.close();
    }
    s_full = s_onFlash >= kMaxRows;
    s_ready = true;
    Serial.printf("[WDLOG] ready rows=%lu cap=%lu\n",
                  (unsigned long)s_onFlash, (unsigned long)kMaxRows);
}

static void flushLocked(void) {
    if (s_bufN == 0) return;
    File f = LittleFS.open(WDLOG_PATH, "a");
    if (!f) { Serial.println("[WDLOG] open failed, keeping rows in RAM"); return; }
    size_t want = (size_t)s_bufN * sizeof(WdLogRecord);
    size_t got = f.write((const uint8_t*)s_buf, want);
    f.close();
    if (got != want) {
        // Count only whole rows that reached flash; the rest stay buffered.
        uint16_t done = (uint16_t)(got / sizeof(WdLogRecord));
        memmove(s_buf, s_buf + done, (size_t)(s_bufN - done) * sizeof(WdLogRecord));
        s_bufN -= done;
        s_onFlash += done;
        Serial.println("[WDLOG] short write, will retry");
        return;
    }
    s_onFlash += s_bufN;
    s_bufN = 0;
}

bool wdLogAppend(const DetectionEvent* evt) {
    if (!s_ready || !evt || s_full) return false;
    if (!hwGpsActive()) return false;
    GpsData g;
    memcpy(&g, (const void*)&currentGps, sizeof(g));
    if ((int64_t)millis() - g.timestamp_ms > (int64_t)WDLOG_FIX_MAX_AGE_MS) return false;
    uint32_t utc = 0;
    if (!hwGpsUtc(&utc)) return false;

    WdLogRecord r = {};
    memcpy(r.mac, evt->mac, 6);
    const bool ble = evt->method == METHOD_BLE_ADV;
    if (ble) {
        strncpy(r.name, evt->ext.wardrive.device_name, sizeof(r.name) - 1);
        r.flags |= WDLOG_FLAG_BLE;
    } else {
        strncpy(r.name, evt->ext.wardrive.ssid, sizeof(r.name) - 1);
        r.auth = evt->ext.wardrive.auth_mode;
    }
    r.channel = evt->channel;
    r.rssi = evt->rssi;
    r.lat_e7 = (int32_t)(g.latitude * 1e7);
    r.lon_e7 = (int32_t)(g.longitude * 1e7);
    r.alt_m = (int16_t)g.altitude;
    float accDm = g.accuracy * 10.0f;
    r.acc_dm = accDm > 65535.0f ? 65535 : (uint16_t)accDm;
    r.utc = utc;

    if (s_mutex) xSemaphoreTake(s_mutex, portMAX_DELAY);
    bool kept = false;
    if (s_onFlash + s_bufN >= kMaxRows) {
        s_full = true;
        Serial.println("[WDLOG] full — offline rows are no longer kept");
    } else {
        if (s_bufN >= WDLOG_BUF_ROWS) flushLocked();
        if (s_bufN < WDLOG_BUF_ROWS) {
            s_buf[s_bufN++] = r;
            kept = true;
        }
    }
    if (s_mutex) xSemaphoreGive(s_mutex);
    return kept;
}

void wdLogFlushIfDue(void) {
    if (!s_ready || s_bufN == 0) return;
    uint32_t now = millis();
    if (now - s_lastFlushMs < WDLOG_FLUSH_MS && s_bufN < WDLOG_BUF_ROWS / 2) return;
    s_lastFlushMs = now;
    if (s_mutex) xSemaphoreTake(s_mutex, portMAX_DELAY);
    flushLocked();
    if (s_mutex) xSemaphoreGive(s_mutex);
}

uint32_t wdLogCount(void) { return s_onFlash + s_bufN; }
bool wdLogFull(void) { return s_full; }

uint16_t wdLogReadBlock(uint32_t index, WdLogRecord* out, uint16_t max) {
    if (!s_ready || !out || max == 0) return 0;
    if (s_mutex) xSemaphoreTake(s_mutex, portMAX_DELAY);
    uint16_t n = 0;
    if (index < s_onFlash) {
        File f = LittleFS.open(WDLOG_PATH, "r");
        if (f && f.seek(index * sizeof(WdLogRecord))) {
            uint32_t avail = s_onFlash - index;
            uint16_t want = avail < max ? (uint16_t)avail : max;
            n = (uint16_t)(f.read((uint8_t*)out, want * sizeof(WdLogRecord)) / sizeof(WdLogRecord));
        }
        if (f) f.close();
    } else if (index < s_onFlash + s_bufN) {
        uint32_t from = index - s_onFlash;
        uint32_t avail = s_bufN - from;
        n = avail < max ? (uint16_t)avail : max;
        memcpy(out, s_buf + from, (size_t)n * sizeof(WdLogRecord));
    }
    if (s_mutex) xSemaphoreGive(s_mutex);
    return n;
}

void wdLogClear(void) {
    if (s_mutex) xSemaphoreTake(s_mutex, portMAX_DELAY);
    if (s_ready) LittleFS.remove(WDLOG_PATH);
    s_onFlash = 0;
    s_bufN = 0;
    s_full = false;
    if (s_mutex) xSemaphoreGive(s_mutex);
}

#endif  // OUISPY_ROLE_MANAGER
