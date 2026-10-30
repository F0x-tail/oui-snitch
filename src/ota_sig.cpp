// SPDX-License-Identifier: MIT
#include "ota_sig.h"
#include "ota_sig_format.h"
#include "ota_pubkey.h"
#include <Arduino.h>
#include <esp_ota_ops.h>
#include <sdkconfig.h>
#include <mbedtls/sha256.h>
#include <mbedtls/ecdsa.h>
#include <mbedtls/version.h>

// mbedtls 3 (IDF 5, the C5 builds) dropped the _ret suffix that 2.28 needs.
#if MBEDTLS_VERSION_MAJOR >= 3
#define sha256Starts mbedtls_sha256_starts
#define sha256Update mbedtls_sha256_update
#define sha256Finish mbedtls_sha256_finish
#define sha256Once   mbedtls_sha256
#else
#define sha256Starts mbedtls_sha256_starts_ret
#define sha256Update mbedtls_sha256_update_ret
#define sha256Finish mbedtls_sha256_finish_ret
#define sha256Once   mbedtls_sha256_ret
#endif

#ifdef OUISPY_ROLE_MANAGER
#define OTA_ROLE "manager"
#else
#define OTA_ROLE "node"
#endif

static const uint32_t OTA_TRIAL_MS = 60000;

const char* otaSigTarget(void) { return OTA_ROLE "-" CONFIG_IDF_TARGET; }

const char* otaSigResultName(OtaSigResult r) {
    switch (r) {
        case OTA_SIG_OK:        return "good signature";
        case OTA_SIG_UNSIGNED:  return "not signed";
        case OTA_SIG_WRONG_KEY: return "signed with another key";
        case OTA_SIG_BAD:       return "bad signature";
        default:                return "read error";
    }
}

static bool hashImage(const esp_partition_t* part, uint32_t len, const char* target,
                      uint8_t out[32]) {
    uint8_t* buf = (uint8_t*)malloc(4096);
    if (!buf) return false;
    mbedtls_sha256_context ctx;
    mbedtls_sha256_init(&ctx);
    bool ok = sha256Starts(&ctx, 0) == 0 &&
              sha256Update(&ctx, (const uint8_t*)OTA_SIG_DOMAIN, strlen(OTA_SIG_DOMAIN)) == 0 &&
              sha256Update(&ctx, (const uint8_t*)target, strlen(target)) == 0 &&
              sha256Update(&ctx, (const uint8_t*)"\n", 1) == 0;
    for (uint32_t off = 0; ok && off < len; off += 4096) {
        uint32_t n = len - off < 4096 ? len - off : 4096;
        ok = esp_partition_read(part, off, buf, n) == ESP_OK &&
             sha256Update(&ctx, buf, n) == 0;
    }
    ok = ok && sha256Finish(&ctx, out) == 0;
    mbedtls_sha256_free(&ctx);
    free(buf);
    return ok;
}

static bool ecdsaVerify(const uint8_t pub[65], const uint8_t hash[32], const uint8_t rs[64]) {
    mbedtls_ecp_group grp;
    mbedtls_ecp_point q;
    mbedtls_mpi r, s;
    mbedtls_ecp_group_init(&grp);
    mbedtls_ecp_point_init(&q);
    mbedtls_mpi_init(&r);
    mbedtls_mpi_init(&s);
    bool ok = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1) == 0 &&
              mbedtls_ecp_point_read_binary(&grp, &q, pub, 65) == 0 &&
              mbedtls_mpi_read_binary(&r, rs, 32) == 0 &&
              mbedtls_mpi_read_binary(&s, rs + 32, 32) == 0 &&
              mbedtls_ecdsa_verify(&grp, hash, 32, &q, &r, &s) == 0;
    mbedtls_mpi_free(&s);
    mbedtls_mpi_free(&r);
    mbedtls_ecp_point_free(&q);
    mbedtls_ecp_group_free(&grp);
    return ok;
}

static void keyIdOf(const uint8_t pub[65], uint8_t id[4]) {
    uint8_t h[32];
    sha256Once(pub, 65, h, 0);
    memcpy(id, h, 4);
}

OtaSigResult otaSigVerifyPartitionWith(const esp_partition_t* part, uint32_t total,
                                       const uint8_t pub[65], const char* target) {
    uint32_t imageLen = otaSigImageLen(total);
    if (!part || imageLen == 0 || total > part->size) return OTA_SIG_UNSIGNED;
    uint8_t trailer[OTA_SIG_TRAILER_LEN];
    if (esp_partition_read(part, imageLen, trailer, sizeof(trailer)) != ESP_OK) return OTA_SIG_IO;
    const uint8_t* keyId;
    const uint8_t* rs;
    if (!otaSigParseTrailer(trailer, &keyId, &rs)) return OTA_SIG_UNSIGNED;
    uint8_t want[4];
    keyIdOf(pub, want);
    if (memcmp(keyId, want, 4) != 0) return OTA_SIG_WRONG_KEY;
    uint8_t hash[32];
    if (!hashImage(part, imageLen, target, hash)) return OTA_SIG_IO;
    return ecdsaVerify(pub, hash, rs) ? OTA_SIG_OK : OTA_SIG_BAD;
}

OtaSigResult otaSigVerifyPartition(const esp_partition_t* part, uint32_t total) {
    OtaSigResult r = otaSigVerifyPartitionWith(part, total, OTA_PUBKEY, otaSigTarget());
    Serial.printf("[OTA] %s: %s\n", otaSigTarget(), otaSigResultName(r));
    return r;
}

// Arduino marks every new image good at boot unless this says otherwise
// (esp32-hal-misc.c); without it the bootloader's rollback never happens.
extern "C" bool verifyRollbackLater() { return true; }

static bool runningPending(void) {
    esp_ota_img_states_t st;
    const esp_partition_t* run = esp_ota_get_running_partition();
    return run && esp_ota_get_state_partition(run, &st) == ESP_OK &&
           st == ESP_OTA_IMG_PENDING_VERIFY;
}

bool otaTrialConfirm(void) {
    if (!runningPending()) return true;
    bool ok = esp_ota_mark_app_valid_cancel_rollback() == ESP_OK;
    Serial.printf("[OTA] new image %s\n", ok ? "confirmed good" : "confirm FAILED");
    return ok;
}

void otaTrialTick(void) {
    static bool done = false;
    if (done || millis() < OTA_TRIAL_MS) return;
    done = true;
    otaTrialConfirm();
}
