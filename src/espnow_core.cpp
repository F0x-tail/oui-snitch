// SPDX-License-Identifier: MIT
//
// Wire protocol and key derivation follow ESP32DualBandWardriver by Just Call
// Me Koko (MIT, Copyright (c) 2025), so that stock nodes from that ecosystem
// can report to us unmodified. Reimplemented here against our own engine and
// queue APIs; the struct layouts, magic, message numbering and key derivation
// are the parts that must match byte for byte.

#include "espnow_core.h"

#include <Arduino.h>
#include <Preferences.h>
#include <string.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <mbedtls/sha256.h>

#include "protocol.h"
#include "radio_coex.h"
#include "engine_registry.h"

// ---------------------------------------------------------------- wire format

#define ENOW_MAGIC        "ENOW"
#define ENOW_TEXT_MAX     200
#define ENOW_RENDEZVOUS_CH 6
#define ENOW_NODE_TIMEOUT_MS 60000u

enum EnowMsgType : uint8_t {
    ENOW_MSG_CORE_REQUEST = 1,
    ENOW_MSG_CORE_REPLY   = 2,
    ENOW_MSG_HEARTBEAT    = 3,
    ENOW_MSG_TEXT         = 4,
    ENOW_MSG_ADMIN        = 5,
};

typedef struct __attribute__((packed)) {
    char     magic[4];
    uint8_t  type;
    uint32_t counter;
    uint16_t len;
    char     text[ENOW_TEXT_MAX + 1];
} EnowTextMsg;

typedef struct __attribute__((packed)) {
    char    magic[4];
    uint8_t type;
    uint8_t assignment_version;
    uint8_t node_index;
    uint8_t node_count;
    uint8_t start_channel_idx;
    uint8_t end_channel_idx;
} EnowAdminMsg;

static_assert(sizeof(EnowTextMsg) == 212, "node firmware expects 212-byte text frames");
static_assert(sizeof(EnowAdminMsg) == 10, "node firmware expects 10-byte admin frames");

// ------------------------------------------------------------------- state

static const uint8_t kBroadcast[6] = {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF};

static bool     s_running = false;
static bool     s_haveKeys = false;
static uint8_t  s_pmk[16];
static uint8_t  s_lmk[16];
static char     s_passphrase[ENOW_PASSPHRASE_MAX + 1] = {0};

static bool     s_allowPlaintext = false;
static bool     s_allowlistOn = false;
static uint8_t  s_allowlist[ENOW_CORE_MAX_NODES][6];
static uint8_t  s_allowCount = 0;

static EspnowCoreNode s_nodes[ENOW_CORE_MAX_NODES];
static uint8_t  s_nodeCount = 0;
static uint8_t  s_assignVersion = 0;
static bool     s_adminDirty[ENOW_CORE_MAX_NODES] = {false};

static uint8_t  s_spanFirst = 0;
static uint8_t  s_spanLast  = 13;

static uint32_t s_recordsRx = 0;
static uint32_t s_rejected = 0;

static const char* kPrefsNs = "ouispy-enow";

// ------------------------------------------------------------ key derivation

// First 16 bytes of SHA-256 over the passphrase plus a context suffix. The
// suffix is what keeps the pairwise key distinct from the primary key; both
// must match the node firmware exactly or nothing decrypts.
static void deriveKey16(const char* phrase, const char* suffix, uint8_t out[16]) {
    uint8_t hash[32];
    mbedtls_sha256_context ctx;
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    mbedtls_sha256_update(&ctx, (const unsigned char*)phrase, strlen(phrase));
    mbedtls_sha256_update(&ctx, (const unsigned char*)suffix, strlen(suffix));
    mbedtls_sha256_finish(&ctx, hash);
    mbedtls_sha256_free(&ctx);
    memcpy(out, hash, 16);
}

static void computeKeys(void) {
    if (!s_passphrase[0]) { s_haveKeys = false; return; }
    deriveKey16(s_passphrase, "_pmk", s_pmk);
    deriveKey16(s_passphrase, "_lmk", s_lmk);
    s_haveKeys = true;
}

bool espnowCoreHasPassphrase(void) { return s_passphrase[0] != 0; }

bool espnowCoreSetPassphrase(const char* phrase) {
    if (!phrase) return false;
    size_t n = strnlen(phrase, ENOW_PASSPHRASE_MAX + 1);
    if (n == 0 || n > ENOW_PASSPHRASE_MAX) return false;

    memset(s_passphrase, 0, sizeof(s_passphrase));
    memcpy(s_passphrase, phrase, n);

    Preferences p;
    p.begin(kPrefsNs, false);
    p.putString("phrase", s_passphrase);
    p.end();

    computeKeys();
    if (s_running) {
        // Rekeying invalidates every peer; drop them and let the nodes
        // re-request rather than leaving half the fleet on the old key.
        esp_now_set_pmk(s_pmk);
        for (uint8_t i = 0; i < s_nodeCount; i++) esp_now_del_peer(s_nodes[i].mac);
        s_nodeCount = 0;
    }
    Serial.println("[ENOW] passphrase set, link keys derived");
    return true;
}

// ------------------------------------------------------------ peer handling

// Delete before add: a peer that already exists with the wrong encryption mode
// is not updated by esp_now_add_peer, it is simply rejected.
static bool addPeer(const uint8_t mac[6], bool encrypt) {
    if (esp_now_is_peer_exist(mac)) {
        esp_now_del_peer(mac);
    }
    esp_now_peer_info_t peer = {};
    memcpy(peer.peer_addr, mac, 6);
    peer.channel = 0;          // follow the current channel rather than pinning
    peer.encrypt = encrypt;
    if (encrypt) memcpy(peer.lmk, s_lmk, 16);
    return esp_now_add_peer(&peer) == ESP_OK;
}

// ------------------------------------------------------------- admission

static bool macAllowed(const uint8_t mac[6]) {
    if (!s_allowlistOn) return true;
    for (uint8_t i = 0; i < s_allowCount; i++) {
        if (memcmp(s_allowlist[i], mac, 6) == 0) return true;
    }
    return false;
}

void espnowCoreAllowlistClear(void) { s_allowCount = 0; }

bool espnowCoreAllowlistAdd(const uint8_t mac[6]) {
    if (s_allowCount >= ENOW_CORE_MAX_NODES) return false;
    memcpy(s_allowlist[s_allowCount++], mac, 6);
    return true;
}

uint8_t espnowCoreAllowlistCount(void) { return s_allowCount; }
bool espnowCoreAllowlistEnabled(void) { return s_allowlistOn; }

void espnowCoreSetAllowlistEnabled(bool on) {
    if (on && s_allowCount == 0) {
        Serial.println("[ENOW] allowlist not enabled — it is empty, which would refuse every node");
        s_allowlistOn = false;
        return;
    }
    s_allowlistOn = on;
}

void espnowCoreSetAllowPlaintext(bool on) {
    s_allowPlaintext = on;
    if (on) Serial.println("[ENOW] WARNING: plaintext nodes accepted — link is unencrypted");
}

// ------------------------------------------------------------- node table

static int findNode(const uint8_t mac[6]) {
    for (uint8_t i = 0; i < s_nodeCount; i++) {
        if (memcmp(s_nodes[i].mac, mac, 6) == 0) return i;
    }
    return -1;
}

// Split the configured channel span into one contiguous range per node. Nodes
// ignore an assignment whose version they have already applied, so re-sending
// is free and a reboot heals itself without us tracking acknowledgements.
static void recalculateAssignments(void) {
    if (s_nodeCount == 0) return;
    uint8_t total = (s_spanLast >= s_spanFirst) ? (s_spanLast - s_spanFirst + 1) : 1;
    uint8_t per = total / s_nodeCount;
    uint8_t extra = total % s_nodeCount;
    uint8_t cursor = s_spanFirst;
    for (uint8_t i = 0; i < s_nodeCount; i++) {
        uint8_t n = per + (i < extra ? 1 : 0);
        if (n == 0) n = 1;
        s_nodes[i].assigned_index = i;
        s_nodes[i].start_channel_idx = cursor;
        s_nodes[i].end_channel_idx = (uint8_t)(cursor + n - 1);
        if (s_nodes[i].end_channel_idx > s_spanLast) s_nodes[i].end_channel_idx = s_spanLast;
        cursor = (uint8_t)(s_nodes[i].end_channel_idx + 1);
        s_adminDirty[i] = true;
    }
    s_assignVersion++;
    Serial.printf("[ENOW] %u node(s), channel span %u..%u redistributed (v%u)\n",
                  s_nodeCount, s_spanFirst, s_spanLast, s_assignVersion);
}

static int adoptNode(const uint8_t mac[6], bool encrypted) {
    if (s_nodeCount >= ENOW_CORE_MAX_NODES) return -1;
    int idx = s_nodeCount++;
    memset(&s_nodes[idx], 0, sizeof(s_nodes[idx]));
    memcpy(s_nodes[idx].mac, mac, 6);
    s_nodes[idx].encrypted = encrypted;
    s_nodes[idx].last_seen_ms = millis();
    recalculateAssignments();
    Serial.printf("[ENOW] node %02X:%02X:%02X:%02X:%02X:%02X joined (%s)\n",
                  mac[0],mac[1],mac[2],mac[3],mac[4],mac[5],
                  encrypted ? "encrypted" : "PLAINTEXT");
    return idx;
}

static void reapStaleNodes(uint32_t now) {
    bool changed = false;
    for (uint8_t i = 0; i < s_nodeCount;) {
        if (now - s_nodes[i].last_seen_ms > ENOW_NODE_TIMEOUT_MS) {
            Serial.printf("[ENOW] node %02X:%02X:%02X:%02X:%02X:%02X timed out\n",
                          s_nodes[i].mac[0],s_nodes[i].mac[1],s_nodes[i].mac[2],
                          s_nodes[i].mac[3],s_nodes[i].mac[4],s_nodes[i].mac[5]);
            esp_now_del_peer(s_nodes[i].mac);
            for (uint8_t k = i; k + 1 < s_nodeCount; k++) {
                s_nodes[k] = s_nodes[k + 1];
                s_adminDirty[k] = s_adminDirty[k + 1];
            }
            s_nodeCount--;
            changed = true;
        } else {
            i++;
        }
    }
    if (changed) recalculateAssignments();
}

uint8_t espnowCoreNodeCount(void) { return s_nodeCount; }

bool espnowCoreNodeAt(uint8_t i, EspnowCoreNode* out) {
    if (i >= s_nodeCount || !out) return false;
    *out = s_nodes[i];
    return true;
}

uint32_t espnowCoreRecordsRx(void) { return s_recordsRx; }
uint32_t espnowCoreRejected(void) { return s_rejected; }

void espnowCoreSetChannelSpan(uint8_t firstIdx, uint8_t lastIdx) {
    if (lastIdx < firstIdx) return;
    s_spanFirst = firstIdx;
    s_spanLast = lastIdx;
    recalculateAssignments();
}

// --------------------------------------------------------- record ingestion

// Nodes report one device per TEXT frame as comma-separated fields:
//
//   WiFi:  BSSID,SSID,SECURITY,CHANNEL,RSSI,W
//   BLE:   MAC,,[BLE],0,RSSI,B
//
// Note the last field: these nodes report Bluetooth as well as WiFi, so the
// type has to be honoured or every BLE sighting is filed as an access point.
// SSIDs have had any commas replaced with underscores by the sender, which is
// why a plain split is safe.

// Their security strings, mapped onto our auth_mode. Anything unrecognised
// falls to open rather than guessing a stronger mode than was observed.
static uint8_t parseSecurity(const char* sec) {
    if (!sec || !*sec) return 0;
    if (strcmp(sec, "[OPEN]") == 0) return 0;
    if (strcmp(sec, "[WEP]") == 0) return 1;
    if (strcmp(sec, "[WPA_PSK]") == 0) return 2;
    if (strcmp(sec, "[WPA2_PSK]") == 0) return 3;
    if (strcmp(sec, "[WPA_WPA2_PSK]") == 0) return 4;
    if (strcmp(sec, "[WPA2]") == 0) return 5;      // their label for WPA2-Enterprise
    if (strcmp(sec, "[WPA3_PSK]") == 0) return 6;
    if (strcmp(sec, "[WPA2_WPA3_PSK]") == 0) return 6;
    return 0;
}

static void ingestRecord(const uint8_t srcMac[6], const char* text, uint16_t len) {
    char buf[ENOW_TEXT_MAX + 1];
    uint16_t n = len < ENOW_TEXT_MAX ? len : ENOW_TEXT_MAX;
    memcpy(buf, text, n);
    buf[n] = 0;

    char* fields[6] = {nullptr};
    uint8_t f = 0;
    char* p = buf;
    fields[f++] = p;
    while (*p && f < 6) {
        if (*p == ',') { *p = 0; fields[f++] = p + 1; }
        p++;
    }
    if (f < 6) { s_rejected++; return; }

    unsigned mac[6];
    if (sscanf(fields[0], "%x:%x:%x:%x:%x:%x",
               &mac[0],&mac[1],&mac[2],&mac[3],&mac[4],&mac[5]) != 6) {
        s_rejected++;
        return;
    }

    const bool isBle = (fields[5][0] == 'B');

    DetectionEvent evt = {};
    evt.engine_id = ENGINE_WARDRIVE;
    for (int i = 0; i < 6; i++) evt.mac[i] = (uint8_t)mac[i];
    evt.rssi = (int8_t)atoi(fields[4]);
    evt.channel = (uint8_t)atoi(fields[3]);
    evt.timestamp_ms = millis();

    if (isBle) {
        evt.method = METHOD_BLE_ADV;
        strncpy(evt.ext.wardrive.device_name, fields[1],
                sizeof(evt.ext.wardrive.device_name) - 1);
    } else {
        evt.method = METHOD_WIFI_AP;
        strncpy(evt.ext.wardrive.ssid, fields[1],
                sizeof(evt.ext.wardrive.ssid) - 1);
        evt.ext.wardrive.auth_mode = parseSecurity(fields[2]);
    }

    // Tag the reporting node so the row is attributable rather than looking
    // like something this board saw itself.
    snprintf(evt.source_node_id, MESH_NODE_ID_LEN, "%02X%02X", srcMac[4], srcMac[5]);

    s_recordsRx++;
    pushDetection(&evt);
}

// ----------------------------------------------------------------- receive

// The receive callback changed shape between IDF major versions; the project
// already keys that off OUISPY_NIMBLE2 elsewhere.
#ifdef OUISPY_NIMBLE2
static void onRecv(const esp_now_recv_info_t* info, const uint8_t* data, int len) {
    const uint8_t* src = info ? info->src_addr : nullptr;
#else
static void onRecv(const uint8_t* src, const uint8_t* data, int len) {
#endif
    if (!s_running || !src || !data || len < 5) return;
    if (memcmp(data, ENOW_MAGIC, 4) != 0) { s_rejected++; return; }

    const uint8_t type = data[4];

    if (!macAllowed(src)) { s_rejected++; return; }

    switch (type) {
        case ENOW_MSG_CORE_REQUEST: {
            // A node looking for a hub. Reply so it learns our address, then
            // let it settle into heartbeats.
            bool encrypt = s_haveKeys;
            if (!encrypt && !s_allowPlaintext) {
                // Refusing is the honest outcome: answering unencrypted would
                // quietly put the whole fleet in the clear.
                Serial.println("[ENOW] CORE_REQUEST refused — no passphrase set");
                s_rejected++;
                return;
            }
            int idx = findNode(src);
            if (idx < 0) {
                if (!addPeer(src, encrypt)) { s_rejected++; return; }
                idx = adoptNode(src, encrypt);
                if (idx < 0) { s_rejected++; return; }
            }
            s_nodes[idx].last_seen_ms = millis();

            EnowTextMsg reply = {};
            memcpy(reply.magic, ENOW_MAGIC, 4);
            reply.type = ENOW_MSG_CORE_REPLY;
            reply.len = 0;
            esp_now_send(src, (const uint8_t*)&reply, sizeof(reply));
            break;
        }
        case ENOW_MSG_HEARTBEAT: {
            int idx = findNode(src);
            if (idx < 0) return;   // unknown node; it must request first
            s_nodes[idx].last_seen_ms = millis();
            // Piggyback the assignment onto the heartbeat: this is the one
            // moment we know the node is parked on the rendezvous channel and
            // listening, so it is the only reliable time to reach it.
            if (s_adminDirty[idx]) {
                EnowAdminMsg admin = {};
                memcpy(admin.magic, ENOW_MAGIC, 4);
                admin.type = ENOW_MSG_ADMIN;
                admin.assignment_version = s_assignVersion;
                admin.node_index = s_nodes[idx].assigned_index;
                admin.node_count = s_nodeCount;
                admin.start_channel_idx = s_nodes[idx].start_channel_idx;
                admin.end_channel_idx = s_nodes[idx].end_channel_idx;
                if (esp_now_send(src, (const uint8_t*)&admin, sizeof(admin)) == ESP_OK) {
                    s_adminDirty[idx] = false;
                }
            }
            break;
        }
        case ENOW_MSG_TEXT: {
            if (len < (int)sizeof(EnowTextMsg)) { s_rejected++; return; }
            int idx = findNode(src);
            if (idx < 0) { s_rejected++; return; }
            if (!s_nodes[idx].encrypted && !s_allowPlaintext) { s_rejected++; return; }
            s_nodes[idx].last_seen_ms = millis();
            const EnowTextMsg* msg = (const EnowTextMsg*)data;
            uint16_t tlen = msg->len;
            if (tlen > ENOW_TEXT_MAX) { s_rejected++; return; }
            ingestRecord(src, msg->text, tlen);
            break;
        }
        default:
            // ADMIN and CORE_REPLY are ours to send, not to receive. A node
            // sending them is either confused or pretending to be a hub.
            s_rejected++;
            break;
    }
}

// ---------------------------------------------------------------- lifecycle

// Interop canary.
//
// If these keys are even one byte off, nothing fails loudly: peers add fine,
// frames go out, and the node simply never decrypts anything. The vectors are
// SHA-256(passphrase || suffix) truncated to 16 bytes, computed independently
// of this code, and they are what the node firmware derives. Checked at boot
// because a silent interop break is worse than a noisy one.
bool espnowCoreSelfTest(void) {
    static const char kPhrase[] = "testmesh";
    static const uint8_t kPmk[16] = {
        0xCC,0x87,0xDB,0xA6,0x04,0x25,0x41,0x16,0x68,0x2C,0x42,0xED,0x7F,0x9E,0x38,0xD2};
    static const uint8_t kLmk[16] = {
        0xF4,0xB0,0xE3,0x98,0x10,0x35,0x97,0x04,0x99,0xFA,0x6D,0x3D,0x2A,0x2E,0xAE,0xB4};

    uint8_t pmk[16], lmk[16];
    deriveKey16(kPhrase, "_pmk", pmk);
    deriveKey16(kPhrase, "_lmk", lmk);

    bool ok = memcmp(pmk, kPmk, 16) == 0 && memcmp(lmk, kLmk, 16) == 0;
    if (!ok) {
        Serial.println("[ENOW] SELFTEST FAILED — link keys will not match node "
                       "firmware and nothing will decrypt");
    }
    return ok;
}

void espnowCoreInit(void) {
    espnowCoreSelfTest();
    Preferences p;
    p.begin(kPrefsNs, true);
    String stored = p.getString("phrase", "");
    s_allowPlaintext = p.getBool("plain", false);
    p.end();
    if (stored.length() > 0 && stored.length() <= ENOW_PASSPHRASE_MAX) {
        memset(s_passphrase, 0, sizeof(s_passphrase));
        memcpy(s_passphrase, stored.c_str(), stored.length());
        computeKeys();
    }
}

bool espnowCoreRunning(void) { return s_running; }

static uint8_t s_lastError = ENOW_ERR_NONE;

uint8_t espnowCoreLastError(void) { return s_lastError; }

// The hub never scans. That is not a nicety: it is the whole reason the
// rendezvous works. A node sets the channel, sends, and leaves, with no
// handshake and no acknowledgement, trusting that someone is parked there
// listening. Any engine that moves the WiFi channel breaks that trust, and it
// breaks it silently — the node sees a successful send, we see nothing, and
// neither side can tell the difference from an idle fleet. So the two are
// mutually exclusive rather than merely warned about, on the same first-come
// terms the PCAP engine already claims the radio on.
static const uint8_t kHoppingEngines =
    ENGINE_BITMASK(ENGINE_WARDRIVE) |
    ENGINE_BITMASK(ENGINE_FLOCK_WIFI) |
    ENGINE_BITMASK(ENGINE_PCAP) |
    ENGINE_BITMASK(ENGINE_SKYSPY);

bool espnowCoreBlocksChannelHopping(void) { return s_running; }

void espnowCoreStart(void) {
    if (s_running) return;
    s_lastError = ENOW_ERR_NONE;

    if (!s_haveKeys && !s_allowPlaintext) {
        Serial.println("[ENOW] refusing to start — no passphrase, and plaintext is not allowed");
        s_lastError = ENOW_ERR_NO_KEY;
        return;
    }

    if (engineGetActiveMask() & kHoppingEngines) {
        Serial.println("[ENOW] refusing to start — a scanning engine owns the "
                       "WiFi channel. The hub must stay parked to hear nodes.");
        s_lastError = ENOW_ERR_SCANNING;
        return;
    }

    if (esp_now_init() != ESP_OK) {
        Serial.println("[ENOW] esp_now_init failed");
        s_lastError = ENOW_ERR_RADIO;
        return;
    }
    if (s_haveKeys && esp_now_set_pmk(s_pmk) != ESP_OK) {
        Serial.println("[ENOW] esp_now_set_pmk failed — link will not encrypt");
    }
    esp_now_register_recv_cb(onRecv);

    // Nodes broadcast CORE_REQUEST until a hub answers, so we must be able to
    // hear a sender we have never seen. The broadcast peer is unencrypted by
    // necessity; it carries no data, only the request.
    addPeer(kBroadcast, false);

    esp_wifi_set_channel(ENOW_RENDEZVOUS_CH, WIFI_SECOND_CHAN_NONE);

    s_running = true;
    Serial.printf("[ENOW] core up on ch%u, %s, allowlist %s\n",
                  ENOW_RENDEZVOUS_CH,
                  s_haveKeys ? "encrypted" : "PLAINTEXT",
                  s_allowlistOn ? "on" : "off");
}

void espnowCoreStop(void) {
    if (!s_running) return;
    for (uint8_t i = 0; i < s_nodeCount; i++) esp_now_del_peer(s_nodes[i].mac);
    esp_now_del_peer(kBroadcast);
    esp_now_unregister_recv_cb();
    esp_now_deinit();
    s_nodeCount = 0;
    s_running = false;
    s_lastError = ENOW_ERR_NONE;
    Serial.println("[ENOW] core down");
}

void espnowCoreTick(void) {
    if (!s_running) return;
    static uint32_t lastReap = 0;
    uint32_t now = millis();
    if (now - lastReap < 1000) return;
    lastReap = now;
    reapStaleNodes(now);
}
