// SPDX-License-Identifier: MIT
#pragma once
#include <stdint.h>
#include "protocol.h"

void detSpoolInit();
void detSpoolAppend(const DetectionEvent* evt);
uint16_t detSpoolCount();
bool detSpoolReadSlot(uint16_t i, DetectionEvent* out, uint16_t* hitCount);
void detSpoolClear();
uint16_t detSpoolDroppedCount();
bool engineSpoolable(uint8_t engine_id);
void detSpoolFlushIfDirty();

// True once the spool has given up writing to flash. Offline detections are
// still collected in RAM, but will not survive a reboot.
bool detSpoolStorageFailed();

#ifdef OUISPY_SPOOL_SELFTEST
void detSpoolSelfTest();
#endif
