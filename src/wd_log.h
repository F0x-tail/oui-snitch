// SPDX-License-Identifier: MIT
#pragma once
#include <stdint.h>
#include "protocol.h"

// Wardrive rows recorded while the phone is away, so a drive continues without
// it. Each row carries the board's own GPS position and GPS time: without a
// position a row is worthless to WiGLE, so nothing is written without a fix.
//
// Append-only on LittleFS, buffered in RAM and written in batches to spare the
// flash. It stops when full rather than overwriting: the oldest part of a
// drive is as valuable as the newest, and the app reports the shortfall.

#pragma pack(push, 1)
typedef struct {
    uint8_t  mac[6];
    char     name[33];   // SSID, or the BLE device name
    uint8_t  auth;       // auth_mode, as DetectionEvent.ext.wardrive
    uint8_t  channel;
    int8_t   rssi;
    uint8_t  flags;      // bit0: BLE
    int32_t  lat_e7;
    int32_t  lon_e7;
    int16_t  alt_m;
    uint16_t acc_dm;     // accuracy, decimetres
    uint32_t utc;        // seconds since 1970, from GPS
} WdLogRecord;
#pragma pack(pop)
static_assert(sizeof(WdLogRecord) == 59, "WdLogRecord is part of the BLE wire format");

#define WDLOG_FLAG_BLE 0x01

void     wdLogInit(void);
// Called for wardrive events while no phone is connected. Returns false when
// the row was not kept: no GPS fix, no GPS time, or the log is full.
bool     wdLogAppend(const DetectionEvent* evt);
void     wdLogFlushIfDue(void);
uint32_t wdLogCount(void);
bool     wdLogFull(void);
// Copies up to [max] rows starting at [index]; returns how many.
uint16_t wdLogReadBlock(uint32_t index, WdLogRecord* out, uint16_t max);
void     wdLogClear(void);
