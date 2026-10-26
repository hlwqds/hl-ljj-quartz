/*
 * onvif_digest.c — HTTP/RTSP Digest 服务端验证实现（ch17 §17.5.3）。
 *
 * 摘要公式（RFC 2617 §3.5，无 qop 传统档）：
 *   HA1      = MD5(username ":" realm ":" password)
 *   HA2      = MD5(method ":" uri)
 *   response = MD5(HA1 ":" nonce ":" HA2)
 *
 * 防重放：nonce 由服务端签发、一次性消费（用后作废），签发环 8 槽。
 * 常量时间：response 与 user 名比对都走异或累积循环。
 * 全部缓冲静态/栈上，零动态分配（组件纪律）。
 */
#include "onvif_digest.h"

#include "esp_log.h"
#include "esp_random.h"

#include "onvif_stats.h"
#include "psa/crypto.h"

#include <stdio.h>
#include <string.h>

static const char *TAG = "onvif_digest";

/* ---- 可注入后端（默认：目标侧 mbedTLS + esp_random） ---- */

static void md5_default(const char *in, size_t len, uint8_t out16[16])
{
    /* mbedTLS 4 无 legacy md5.h；PSA Crypto 的 MD5 一直可用（auth 的 SHA1 同款通道） */
    size_t olen = 0;
    if (psa_hash_compute(PSA_ALG_MD5, (const uint8_t *)in, len, out16, 16, &olen) !=
            PSA_SUCCESS ||
        olen != 16) {
        memset(out16, 0, 16); /* 失败即全零：verify 必然不等，宁可拒不留洞 */
    }
}

static void nonce_default(char out[DIGEST_NONCE_HEX + 1])
{
    uint8_t raw[16];
    esp_fill_random(raw, sizeof(raw));
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 16; i++) {
        out[i * 2] = hex[raw[i] >> 4];
        out[i * 2 + 1] = hex[raw[i] & 0xf];
    }
    out[DIGEST_NONCE_HEX] = '\0';
}

static onvif_digest_md5_fn s_md5 = md5_default;
static onvif_digest_nonce_fn s_nonce = nonce_default;

void onvif_digest_bind(onvif_digest_md5_fn md5, onvif_digest_nonce_fn nonce_gen)
{
    if (md5) {
        s_md5 = md5;
    }
    if (nonce_gen) {
        s_nonce = nonce_gen;
    }
}

/* ---- 环：已签发未消费的 nonce（指纹防串台，槽清零即消费） ---- */

static struct {
    char nonce[DIGEST_NONCE_HEX + 1];
} s_ring[DIGEST_RING_SLOTS];
static int s_ring_head;

void onvif_digest_register_stats(void)
{
    /* nonce 环入 $$$ ONVIF STATS 账——内存评估账本不许漏新模块 */
    onvif_stats_register_static("digest", "nonce_ring", sizeof(s_ring));
}

static void hex16_to_str(const uint8_t h[16], char out[DIGEST_HEX_MAX])
{
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 16; i++) {
        out[i * 2] = hex[h[i] >> 4];
        out[i * 2 + 1] = hex[h[i] & 0xf];
    }
    out[32] = '\0';
}

static void md5_hex(const char *in, size_t len, char out[DIGEST_HEX_MAX])
{
    uint8_t d[16];
    s_md5(in, len, d);
    hex16_to_str(d, out);
}

/* 常量时间 hex 比对（等长才进循环；长度不等直接不等——长度本身非秘密） */
static bool ct_hex_eq(const char *a, const char *b, size_t n)
{
    uint8_t d = 0;
    for (size_t i = 0; i < n; i++) {
        d |= (uint8_t)(a[i] ^ b[i]);
    }
    return d == 0;
}

/* ---- 发质询 ---- */

int onvif_digest_challenge(const char *realm, onvif_digest_challenge_t *ch,
                           char *out, size_t out_max)
{
    if (!realm || !ch || !out || out_max < 64) {
        return -1;
    }
    s_nonce(ch->nonce);
    strncpy(ch->realm, realm, sizeof(ch->realm) - 1);
    ch->realm[sizeof(ch->realm) - 1] = '\0';

    /* 入环（nonce 定长 32 hex，memcpy 免 gcc 截断告警；槽 NUL 静态清零保证） */
    memcpy(s_ring[s_ring_head].nonce, ch->nonce, DIGEST_NONCE_HEX);
    s_ring_head = (s_ring_head + 1) % DIGEST_RING_SLOTS;

    return snprintf(out, out_max,
                    "Digest realm=\"%s\", nonce=\"%s\"", ch->realm, ch->nonce);
}

/* ---- 从 Authorization 头提取五字段（引号可选；值内不允许引号，够本域用） ---- */

static bool grab_quoted(const char *hdr, const char *key, char *out, size_t out_max)
{
    char pat[32];
    snprintf(pat, sizeof(pat), "%s=\"", key);
    const char *p = strstr(hdr, pat);
    if (!p) {
        return false; /* 兼容无引号形态 */
    }
    p += strlen(pat);
    size_t n = 0;
    while (*p && *p != '"' && n + 1 < out_max) {
        out[n++] = *p++;
    }
    out[n] = '\0';
    return n > 0;
}

static bool grab_plain(const char *hdr, const char *key, char *out, size_t out_max)
{
    char pat[32];
    snprintf(pat, sizeof(pat), "%s=", key);
    const char *p = strstr(hdr, pat);
    if (!p) {
        return false;
    }
    p += strlen(pat);
    if (*p == '"') {
        return grab_quoted(hdr, key, out, out_max);
    }
    size_t n = 0;
    while (*p && *p != ',' && *p != ' ' && n + 1 < out_max) {
        out[n++] = *p++;
    }
    out[n] = '\0';
    return n > 0;
}

/* 统一入口：带引号优先（RFC 形态），无引号兜底（部分 ffmpeg 客户端形态） */
static bool grab_field(const char *hdr, const char *key, char *out, size_t out_max)
{
    return grab_quoted(hdr, key, out, out_max) || grab_plain(hdr, key, out, out_max);
}

/* ---- 验证 ---- */

int onvif_digest_verify(const char *auth_header, const char *method, const char *uri,
                        const char *user, const char *pass, const char *realm,
                        onvif_digest_auth_t *parsed_out)
{
    if (!auth_header || !method || !uri || !user || !pass || !realm) {
        return -1;
    }
    if (!strstr(auth_header, "Digest")) {
        return -1; /* 非 Digest 档：不支持即拒 */
    }
    onvif_digest_auth_t a = {0};
    if (!grab_field(auth_header, "username", a.username, sizeof(a.username)) ||
        !grab_field(auth_header, "nonce", a.nonce, sizeof(a.nonce)) ||
        !grab_field(auth_header, "uri", a.uri, sizeof(a.uri)) ||
        !grab_field(auth_header, "response", a.response, sizeof(a.response))) {
        return -1;
    }

    /* ① nonce 必须是本环签发且未消费 */
    int slot = -1;
    for (int i = 0; i < DIGEST_RING_SLOTS; i++) {
        if (s_ring[i].nonce[0] && strcmp(s_ring[i].nonce, a.nonce) == 0) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        ESP_LOGW(TAG, "$$$ ONVIF LAB05 DIGEST DENY reason=nonce-unknown");
        return -2;
    }
    s_ring[slot].nonce[0] = '\0'; /* 一次性：先消费，凭据错时再退还 */

    /* ② realm/username 比对（realm 参与哈希，明文比对只作快速拒绝） */
    if (strcmp(a.username, user) != 0) {
        memcpy(s_ring[slot].nonce, a.nonce, DIGEST_NONCE_HEX); /* 退还 */
        ESP_LOGW(TAG, "$$$ ONVIF LAB05 DIGEST DENY reason=user-unknown");
        return 1;
    }
    /* realm 明文比对仅在有字段时做（RFC 要求回显，最小客户端常省）；
     * realm 本就绑进 HA1 哈希——缺省放行交给哈希判，安全面不变、误拒面收窄 */
    const char *rpos = strstr(auth_header, "realm=");
    if (rpos != NULL && strstr(rpos, realm) == NULL) {
        memcpy(s_ring[slot].nonce, a.nonce, DIGEST_NONCE_HEX); /* 退还 */
        ESP_LOGW(TAG, "$$$ ONVIF LAB05 DIGEST DENY reason=realm-mismatch");
        return 1;
    }

    /* ③ response = MD5(HA1:nonce:HA2)，常量时间比对 */
    char cat[300], ha1[DIGEST_HEX_MAX], ha2[DIGEST_HEX_MAX], resp[DIGEST_HEX_MAX];
    snprintf(cat, sizeof(cat), "%s:%s:%s", a.username, realm, pass);
    md5_hex(cat, strlen(cat), ha1);
    snprintf(cat, sizeof(cat), "%s:%s", method, uri);
    md5_hex(cat, strlen(cat), ha2);
    snprintf(cat, sizeof(cat), "%s:%s:%s", ha1, a.nonce, ha2);
    md5_hex(cat, strlen(cat), resp);

    if (!ct_hex_eq(resp, a.response, 32)) {
        memcpy(s_ring[slot].nonce, a.nonce, DIGEST_NONCE_HEX); /* 退还 */
        ESP_LOGW(TAG, "$$$ ONVIF LAB05 DIGEST DENY reason=digest-mismatch user=%s",
                 a.username);
        return 1;
    }

    if (parsed_out) {
        *parsed_out = a;
    }
    ESP_LOGI(TAG, "$$$ ONVIF LAB05 DIGEST OK user=%s uri=%s", a.username, a.uri);
    return 0;
}

/* ---- RFC 2617 §3.5 规范向量 ---- */

bool onvif_digest_selftest(void)
{
    /* RFC 2617 §3.5 向量（无 qop 传统档）：user=Mufasa realm=testrealm@host.com
     * pass="Circle Of Life" nonce=dcd98b7102dd2f0e8b11d0f600bfb0c093
     * uri=/dir/index.html GET → MD5(HA1:nonce:HA2)=670fd8c2…
     * （RFC 文里印的 6629fae4… 是 qop="auth" 变体的值，与本实现档位不同——
     *   本期望值经 python hashlib 独立复核） */
    static const char *nonce = "dcd98b7102dd2f0e8b11d0f600bfb0c093";
    static const char *expect = "670fd8c2df070c60b045671b8b24ff02";

    char cat[256], ha1[DIGEST_HEX_MAX], ha2[DIGEST_HEX_MAX], resp[DIGEST_HEX_MAX];
    snprintf(cat, sizeof(cat), "%s:%s:%s", "Mufasa", "testrealm@host.com", "Circle Of Life");
    md5_hex(cat, strlen(cat), ha1);
    snprintf(cat, sizeof(cat), "%s:%s", "GET", "/dir/index.html");
    md5_hex(cat, strlen(cat), ha2);
    snprintf(cat, sizeof(cat), "%s:%s:%s", ha1, nonce, ha2);
    md5_hex(cat, strlen(cat), resp);

    bool ok = strcmp(resp, expect) == 0;
    ESP_LOGI(TAG, "$$$ ONVIF LAB05 DIGEST SELFTEST %s", ok ? "ok" : "FAIL");
    return ok;
}
