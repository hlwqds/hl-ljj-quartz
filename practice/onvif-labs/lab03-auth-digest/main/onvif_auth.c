/*
 * onvif_auth.c — WS-Security UsernameToken 摘要认证设备侧验证器（lab03）。
 *
 * 公式与 ch04 逐字相同：PasswordDigest = Base64(SHA1(b64decode(Nonce) + Created + Password))。
 * 字节观三纪律：nonce 参与 SHA1 的是解码后原始字节（非头里的 base64 文本）、Created 是
 * 原样字符串、口令取明文 UTF-8（onvif_secrets.h 编译期注入，gitignore 纪律同 wifi_secrets）。
 * 判据链顺序 = 排错大纲：user → decode → digest → clock → replay；对外统一
 * ter:NotAuthorized，分因只落板端 run.log（ch04 抱怨的「设备不告诉你哪错了」的解法）。
 */
#include "onvif_auth.h"
#include "onvif_secrets.h"

#include "esp_log.h"
#include "esp_sntp.h"
#include "mbedtls/base64.h"
#include "nvs.h"
#include "psa/crypto.h"
#include <string.h>
#include <time.h>

#define AUTH_WINDOW_S   300 /* ±300s，对齐 ch04「±5 分钟量级」 */
#define AUTH_RING_SLOTS 64  /* 64 槽 × 20B 指纹 = 1,280B 静态 BSS */
#define AUTH_RING_FP    20
#define AUTH_NONCE_MAX  32  /* nonce 原始字节上限（>44B b64 文本即拒） */
#define AUTH_NVS_NS     "onvif"
#define AUTH_NVS_KEY    "sntp_en"

static const char *TAG = "onvif_auth";

/* nonce 环：存 SHA1(nonce) 指纹——定长槽、任意 nonce 长度通吃；零锁（httpd 单线程）。 */
static uint8_t s_ring[AUTH_RING_SLOTS][AUTH_RING_FP];
static uint8_t s_ring_head;
static bool s_sntp_enabled;

const char *onvif_auth_username(void)
{
    return ONVIF_AUTH_USER;
}

const char *onvif_auth_reason(auth_rc_t rc)
{
    switch (rc) {
    case AUTH_OK:              return "ok";
    case AUTH_NO_TOKEN:        return "no_token";
    case AUTH_BAD_TOKEN:       return "bad_token";
    case AUTH_USER_UNKNOWN:    return "user_unknown";
    case AUTH_DIGEST_MISMATCH: return "digest_mismatch";
    case AUTH_CLOCK_SKEW:      return "clock_skew";
    case AUTH_NONCE_REPLAY:    return "nonce_replay";
    default:                   return "unknown";
    }
}

/* 常量时间比对：异或累加三行，比对失败不提前返回 */
static bool ct_equal(const uint8_t *a, const uint8_t *b, size_t n)
{
    uint8_t d = 0;
    for (size_t i = 0; i < n; i++) {
        d |= (uint8_t)(a[i] ^ b[i]);
    }
    return d == 0;
}

/* days_from_civil（Hinnant）：公历日 → Unix 天数，无库依赖 */
static long days_from_civil(int y, int m, int d)
{
    y -= m <= 2;
    long era = (y >= 0 ? y : y - 399) / 400;
    int yoe = y - (int)(era * 400);
    int doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    int doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

/* Created 固定形态解析：YYYY-MM-DDTHH:MM:SS 后接 Z 或 +00:00（zeep 实测发 +00:00）。
 * 非零时区偏移不宽容（已知边界，ch14 §14.2）：窗口只认 UTC 时刻，摘要对的是原样字符串。 */
static bool created_epoch(const char *s, long long *out)
{
    int y, mo, d, h, mi, se;
    char rest[8] = {0};
    if (s == NULL || sscanf(s, "%4d-%2d-%2dT%2d:%2d:%2d%7s", &y, &mo, &d, &h, &mi,
                            &se, rest) != 7) {
        return false;
    }
    if (strcmp(rest, "Z") != 0 && strcmp(rest, "+00:00") != 0) {
        return false;
    }
    if (y < 1970 || mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || se > 60) {
        return false;
    }
    *out = (long long)days_from_civil(y, mo, d) * 86400LL + h * 3600LL + mi * 60LL + se;
    return true;
}

/* 定向提取 <前缀:Local ...>text</...> 的 text（不做 DOM，沿用 lab01 disc_extract 同款）。
 * 命中判定：local 前是 ':'、前缀前是 '<'、local 后是 '>' 或属性；Password/Nonce 带
 * 属性形态（Type=/EncodingType=）由「读到 '>' 才开始取文本」消化。 */
static bool tag_value(const char *rx, const char *local, char *out, size_t out_max)
{
    const char *p = rx;
    while ((p = strstr(p, local)) != NULL) {
        const char *lt = p - 1; /* local 前一个字符应是 ':' */
        char after = p[strlen(local)];
        /* 复合名防误命中：UsernameToken 含 "Username"，local 后必须是 '>' 或属性分隔 */
        if (after != '>' && after != ' ' && after != '\t' && after != '\r' && after != '\n') {
            p += strlen(local);
            continue;
        }
        if (lt >= rx + 1 && *lt == ':') {
            /* 找到本标签名前面最近的 '<'，确认中间是纯前缀（无空格/引号） */
            const char *q = lt - 1;
            while (q >= rx && *q != '<' && *q != ' ') {
                q--;
            }
            if (q >= rx && *q == '<') {
                const char *gt = strchr(p + strlen(local), '>');
                if (gt != NULL) {
                    const char *end = strchr(gt + 1, '<');
                    if (end != NULL) {
                        size_t n = (size_t)(end - gt - 1);
                        if (n < out_max) {
                            memcpy(out, gt + 1, n);
                            out[n] = '\0';
                            return true;
                        }
                        return false; /* 超长即拒 */
                    }
                }
            }
        }
        p += strlen(local);
    }
    return false;
}

static bool nonce_ring_hit(const uint8_t *nonce, size_t n)
{
    uint8_t fp[AUTH_RING_FP];
    size_t fp_len = 0;
    if (psa_hash_compute(PSA_ALG_SHA_1, nonce, n, fp, sizeof(fp), &fp_len) != PSA_SUCCESS ||
        fp_len != AUTH_RING_FP) {
        return false;
    }
    for (int i = 0; i < AUTH_RING_SLOTS; i++) {
        if (memcmp(s_ring[i], fp, AUTH_RING_FP) == 0) {
            return true; /* 全零槽是 20B 零指纹，无实际原像，教学形态不做占用位图 */
        }
    }
    return false;
}

static void nonce_ring_add(const uint8_t *nonce, size_t n)
{
    size_t fp_len = 0;
    psa_hash_compute(PSA_ALG_SHA_1, nonce, n, s_ring[s_ring_head], AUTH_RING_FP,
                     &fp_len); /* 轮转覆盖最旧；只在全校验通过后调用 */
    s_ring_head = (uint8_t)((s_ring_head + 1) % AUTH_RING_SLOTS);
}

static auth_rc_t finish(auth_rc_t rc, const char *user)
{
    if (rc == AUTH_OK) {
        ESP_LOGI(TAG, "$$$ ONVIF LAB03 AUTH ok user=%s", user);
    } else {
        ESP_LOGI(TAG, "$$$ ONVIF LAB03 AUTH deny reason=%s user=%s",
                 onvif_auth_reason(rc), user);
    }
    return rc;
}

auth_rc_t onvif_auth_verify(const char *rx)
{
    char user[32] = {0}, nonce_b64[64] = {0}, created[40] = {0}, digest_b64[48] = {0};
    uint8_t nonce[AUTH_NONCE_MAX];
    size_t nlen = sizeof(nonce), glen = AUTH_RING_FP;

    /* wsse 命名空间 URI 前缀无关判存（zeep/探针的 wsse 前缀都指向同一 URI） */
    if (strstr(rx, "oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext") == NULL) {
        return finish(AUTH_NO_TOKEN, "-");
    }
    if (!tag_value(rx, "Username", user, sizeof(user)) ||
        !tag_value(rx, "Nonce", nonce_b64, sizeof(nonce_b64)) ||
        !tag_value(rx, "Created", created, sizeof(created)) ||
        !tag_value(rx, "Password", digest_b64, sizeof(digest_b64))) {
        return finish(AUTH_BAD_TOKEN, user[0] ? user : "-");
    }

    if (strcmp(user, ONVIF_AUTH_USER) != 0) {
        return finish(AUTH_USER_UNKNOWN, user); /* 与错口令同拒外相，防花名册枚举 */
    }
    if (mbedtls_base64_decode(nonce, sizeof(nonce), &nlen,
                              (const uint8_t *)nonce_b64, strlen(nonce_b64)) != 0 ||
        nlen == 0) {
        return finish(AUTH_BAD_TOKEN, user);
    }

    /* SHA1(解码后 nonce 字节 + Created 原样字符串 + 口令 UTF-8)：三段拼进栈上
     * blob 后 psa_hash_compute 一把出（mbedtls4 无经典流式 SHA1，PSA 是正路） */
    uint8_t blob[AUTH_NONCE_MAX + 40 + 64];
    size_t pass_len = strlen(ONVIF_AUTH_PASS), created_len = strlen(created);
    if (nlen + created_len + pass_len > sizeof(blob)) {
        return finish(AUTH_BAD_TOKEN, user);
    }
    memcpy(blob, nonce, nlen);
    memcpy(blob + nlen, created, created_len);
    memcpy(blob + nlen + created_len, ONVIF_AUTH_PASS, pass_len);

    uint8_t calc[AUTH_RING_FP], got[AUTH_RING_FP];
    size_t calc_len = 0;
    if (psa_hash_compute(PSA_ALG_SHA_1, blob, nlen + created_len + pass_len, calc,
                         sizeof(calc), &calc_len) != PSA_SUCCESS ||
        calc_len != AUTH_RING_FP) {
        return finish(AUTH_BAD_TOKEN, user);
    }

    if (mbedtls_base64_decode(got, sizeof(got), &glen, (const uint8_t *)digest_b64,
                              strlen(digest_b64)) != 0 ||
        glen != AUTH_RING_FP || !ct_equal(calc, got, AUTH_RING_FP)) {
        return finish(AUTH_DIGEST_MISMATCH, user);
    }

    long long made = 0;
    if (!created_epoch(created, &made)) {
        return finish(AUTH_BAD_TOKEN, user);
    }
    long long now = (long long)time(NULL);
    long long diff = now - made;
    if (diff < -AUTH_WINDOW_S || diff > AUTH_WINDOW_S) {
        return finish(AUTH_CLOCK_SKEW, user); /* ch09 坑 1 的判定点 */
    }
    if (nonce_ring_hit(nonce, nlen)) {
        return finish(AUTH_NONCE_REPLAY, user);
    }
    nonce_ring_add(nonce, nlen); /* 全校验通过才记账：失败请求不占坑 */
    return finish(AUTH_OK, user);
}

/* ---- SNTP：时钟纪律治本件；教学开关 sntp on|off 落 NVS，重启保持 ---- */

static void sntp_sync_cb(struct timeval *tv)
{
    ESP_LOGI(TAG, "$$$ ONVIF LAB03 SNTP synced epoch=%lld", (long long)tv->tv_sec);
}

static void sntp_start(void)
{
    if (esp_sntp_enabled()) {
        return;
    }
    esp_sntp_setoperatingmode(ESP_SNTP_OPMODE_POLL);
    esp_sntp_setservername(0, "ntp.aliyun.com");
    esp_sntp_setservername(1, "pool.ntp.org");
    esp_sntp_set_time_sync_notification_cb(sntp_sync_cb);
    esp_sntp_init(); /* POLL 模式 init 即发起一轮查询 */
    ESP_LOGI(TAG, "sntp started servers=ntp.aliyun.com,pool.ntp.org");
}

void onvif_auth_sntp_set(bool enable)
{
    nvs_handle_t h;
    if (nvs_open(AUTH_NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_u8(h, AUTH_NVS_KEY, enable ? 1 : 0);
        nvs_commit(h);
        nvs_close(h);
    }
    s_sntp_enabled = enable;
    if (enable) {
        sntp_start();
    } else if (esp_sntp_enabled()) {
        esp_sntp_stop();
        ESP_LOGI(TAG, "sntp stopped"); /* 复现坑 1 的教学开关：重启后板钟停纪元 */
    }
}

bool onvif_auth_sntp_enabled(void)
{
    return s_sntp_enabled;
}

esp_err_t onvif_auth_init(void)
{
    memset(s_ring, 0, sizeof(s_ring));
    s_ring_head = 0;
    if (psa_crypto_init() != PSA_SUCCESS) { /* PSA 子系统一次初始化，SHA1 走 psa_hash_compute */
        ESP_LOGE(TAG, "psa_crypto_init failed");
        return ESP_FAIL;
    }

    nvs_handle_t h;
    uint8_t en = 1; /* 默认开：治本路径是常态，教学实验才关 */
    if (nvs_open(AUTH_NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        nvs_get_u8(h, AUTH_NVS_KEY, &en);
        nvs_close(h);
    }
    s_sntp_enabled = en != 0;
    if (s_sntp_enabled) {
        sntp_start();
    }
    ESP_LOGI(TAG, "$$$ ONVIF LAB03 AUTH READY sntp=%s window_s=%d ring=%dx%dB user=%s",
             s_sntp_enabled ? "on" : "off", AUTH_WINDOW_S, AUTH_RING_SLOTS,
             AUTH_RING_FP, ONVIF_AUTH_USER);
    return ESP_OK;
}
