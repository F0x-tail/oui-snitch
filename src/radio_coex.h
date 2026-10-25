// SPDX-License-Identifier: MIT
#pragma once
#include <stdint.h>
#include "esp_wifi.h"

typedef void (*WifiRxParser)(void* buf, wifi_promiscuous_pkt_type_t type);

void wifiCoexRegister(WifiRxParser parser, uint32_t filterMask);
void wifiCoexUnregister(WifiRxParser parser);
#ifdef OUISPY_NIMBLE2
void c5WifiInitNetif(void);
void c5WifiUp(void);
#endif
bool wifiCoexActive(void);
bool wifiRadioExternallyOwned(void);
bool wifiCoexShouldHop(int engineId);

void wifiSnifferApplyPs(void);

// Recovery for a wedged sniffer — see the watchdog in the wardrive engine.
// Re-asserts promiscuous mode and our dispatch hook; safe with other engines
// registered, because it changes nothing they depend on.
void wifiCoexReassertPromiscuous(void);
// Harder recovery: stop and restart the radio. Only legal when nothing else is
// registered, so it cannot pull the radio out from under another engine.
bool wifiCoexCycleRadio(void);
int  wifiCoexParserCount(void);

#define WIFI_BAND_24 0x01
#define WIFI_BAND_5  0x02

void    wifiSetBandMask(uint8_t mask);
uint8_t wifiGetBandMask(void);
bool    wifiChanEnabled(uint8_t ch);
void    wifiApplyRegdomain(void);
