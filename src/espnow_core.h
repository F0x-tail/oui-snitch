// SPDX-License-Identifier: MIT
#ifndef ESPNOW_CORE_H
#define ESPNOW_CORE_H

#include <stdint.h>

// Hub ("Core") for third-party ESP-NOW wardriving nodes.
//
// Wire-compatible with the ESP32DualBandWardriver protocol by Just Call Me
// Koko (MIT, https://github.com/justcallmekoko/ESP32DualBandWardriver), which
// several node firmwares in that ecosystem speak. Nodes sweep the channels
// they are assigned and report networks; this side parks on the rendezvous
// channel, never scans, and hands out assignments.
//
// This is a separate peer population from our own mesh, which keeps its own
// stronger AES-256-GCM protocol. Nothing here changes that link.

#define ENOW_CORE_MAX_NODES   24
#define ENOW_PASSPHRASE_MAX   64

// Why the last start attempt refused. Cleared on a successful start or stop,
// so the app can explain a button that appeared to do nothing.
#define ENOW_ERR_NONE      0
#define ENOW_ERR_NO_KEY    1
#define ENOW_ERR_SCANNING  2
#define ENOW_ERR_RADIO     3
uint8_t espnowCoreLastError(void);

// True while the hub holds the rendezvous channel. The engine registry asks
// this before starting anything that would hop away from it.
bool espnowCoreBlocksChannelHopping(void);

// Lifecycle. init() is cheap and safe to call before a passphrase exists.
void espnowCoreInit(void);
// Verifies key derivation against vectors the node firmware also produces.
bool espnowCoreSelfTest(void);
void espnowCoreStart(void);
void espnowCoreStop(void);
void espnowCoreTick(void);
bool espnowCoreRunning(void);

// The shared secret the ESP-NOW link keys are derived from. Provisioned over
// the paired BLE link and stored in NVS; it is never transmitted over the air.
// Returns false if the passphrase is too long or empty.
bool espnowCoreSetPassphrase(const char* phrase);
bool espnowCoreHasPassphrase(void);

// Admission control. The protocol authenticates nothing beyond possession of
// the shared key, so anyone holding the passphrase is otherwise trusted. An
// allowlist is the only real gate, and it costs a stock node nothing.
void espnowCoreAllowlistClear(void);
bool espnowCoreAllowlistAdd(const uint8_t mac[6]);
uint8_t espnowCoreAllowlistCount(void);
// With the allowlist empty, every node is accepted. Turning this on with an
// empty list would refuse everything, so it is reported separately.
void espnowCoreSetAllowlistEnabled(bool on);
bool espnowCoreAllowlistEnabled(void);

// Whether a node may talk to us unencrypted. Off by default: other firmwares
// in this ecosystem ship with encryption disabled, and accepting them would
// silently drop the whole fleet to plaintext.
void espnowCoreSetAllowPlaintext(bool on);

// Channel range handed out to nodes, as indices into the shared channel table.
void espnowCoreSetChannelSpan(uint8_t firstIdx, uint8_t lastIdx);

typedef struct {
    uint8_t  mac[6];
    uint32_t last_seen_ms;
    uint8_t  assigned_index;
    uint8_t  start_channel_idx;
    uint8_t  end_channel_idx;
    bool     encrypted;
} EspnowCoreNode;

uint8_t espnowCoreNodeCount(void);
bool    espnowCoreNodeAt(uint8_t i, EspnowCoreNode* out);
uint32_t espnowCoreRecordsRx(void);
uint32_t espnowCoreRejected(void);

#endif
