// SPDX-License-Identifier: MIT
#ifndef EXPOSURE_CHECK_H
#define EXPOSURE_CHECK_H

#include <stdint.h>
#include <stddef.h>

// "What does my phone give away?" (rules in ../exposure.h). Started by the
// app; the user switches their phone's Wi-Fi off and on during the watch
// window. Passive: the board only listens. Runs on its own task, pausing the
// scan engines for about 21 s and restoring them after.
//
// Progress and the result go to the phone through [notify], each message
// starting with SYS_OP_EXPOSURE and a phase byte (ExpoPhase); the result
// follows the EXPO_DONE phase in expoEncode's layout.
typedef void (*ExposureNotify)(const uint8_t* data, size_t len);

#define SYS_OP_EXPOSURE 0x11

void exposureCheckStart(ExposureNotify notify);
bool exposureCheckBusy(void);

#endif // EXPOSURE_CHECK_H
