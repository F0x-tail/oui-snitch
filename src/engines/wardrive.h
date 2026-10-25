// SPDX-License-Identifier: MIT
#ifndef WARDRIVE_H
#define WARDRIVE_H

#include "../engine_registry.h"

extern const EngineCallbacks wardriveCallbacks;

uint16_t wardriveGetBleScanDurationMs(void);
uint16_t wardriveGetBleScanIntervalMs(void);
uint8_t  wardriveGetRadio(void);
void     wardriveSetRadioMask(uint8_t mask);
void     wardriveSetDwell(uint16_t pri, uint16_t norm);
void     wardriveSetActiveProbe(bool on);
bool     wardriveGetActiveProbe(void);
uint32_t wardriveGetHopCount(void);
uint32_t wardriveGetMeshSkipCount(void);

#endif // WARDRIVE_H
