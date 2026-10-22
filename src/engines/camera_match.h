#ifndef CAMERA_MATCH_H
#define CAMERA_MATCH_H

#include <stdint.h>
#include <string.h>
#include <strings.h>
#include "camera_oui.h"

// Consumer / IP surveillance camera matching.
//
// Two independent signals feed a confidence tier, mirroring the Flock engine:
//   * OUI registered to a camera vendor      (camera_oui.h)
//   * BLE advertised name or Wi-Fi SSID      (CAMERA_NAME_PATTERNS below)
//
// A bare OUI is reported as SUSPECTED only: a vendor OUI appears on every device
// that vendor ships, not just its cameras. A name hit is specific enough on its
// own; name + OUI together is treated as VERIFIED.

enum CameraConf : uint8_t {
    CAMERA_CONF_NONE      = 0,
    CAMERA_CONF_SUSPECTED = 1,
    CAMERA_CONF_HIGH      = 2,
    CAMERA_CONF_VERIFIED  = 3,
};

// Substrings matched case-insensitively against BLE names and Wi-Fi SSIDs.
// Kept deliberately specific: a bare "ring" or "cam" would match unrelated
// SSIDs ("Springfield", "Camden"), so only distinctive tokens are listed.
static const char* CAMERA_NAME_PATTERNS[] = {
    "Ring-", "RingSetup",          // Ring doorbells/cams setup AP
    "Wyze", "WyzeCam",
    "Arlo",
    "Reolink",
    "Amcrest",
    "Lorex",
    "Swann",
    "eufy",
    "Tapo",                        // TP-Link Tapo cameras
    "KASA",
    "Wansview",
    "Foscam",
    "EZVIZ",
    "Nestcam", "Nest Cam",         // not bare "Nest": also thermostats/speakers
    "Blink",
    "HIKVISION", "HIK-",
    "Dahua",
    "IPCAM", "IPC-",               // common generic IP-camera SSID prefixes
    "Doorbell",
};
static const int CAMERA_NAME_PATTERN_COUNT =
    sizeof(CAMERA_NAME_PATTERNS) / sizeof(CAMERA_NAME_PATTERNS[0]);

// Returns the matched pattern, or nullptr.
static inline const char* cameraMatchName(const char* s) {
    if (!s || !s[0]) return nullptr;
    for (int i = 0; i < CAMERA_NAME_PATTERN_COUNT; i++) {
        if (strcasestr(s, CAMERA_NAME_PATTERNS[i])) return CAMERA_NAME_PATTERNS[i];
    }
    return nullptr;
}

// Combine the signals into a confidence tier.
static inline CameraConf cameraScore(const char* ouiVendor, const char* nameHit) {
    if (ouiVendor && nameHit) return CAMERA_CONF_VERIFIED;
    if (nameHit)              return CAMERA_CONF_HIGH;
    if (ouiVendor)            return CAMERA_CONF_SUSPECTED;
    return CAMERA_CONF_NONE;
}

static inline const char* cameraConfName(CameraConf c) {
    switch (c) {
        case CAMERA_CONF_VERIFIED:  return "VERIFIED";
        case CAMERA_CONF_HIGH:      return "HIGH";
        case CAMERA_CONF_SUSPECTED: return "SUSPECTED";
        default:                    return "NONE";
    }
}

#endif // CAMERA_MATCH_H
