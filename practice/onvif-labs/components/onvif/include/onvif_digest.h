/*
 * onvif_digest.h — HTTP/RTSP Digest 服务端验证（RFC 2617/7850，ch17 §17.5.3）。
 *
 * 与 WS-Security（onvif_auth）是两套摘要：这里是 MD5(HA1:nonce:HA2)，
 * HA1=MD5(user:realm:pass)、HA2=MD5(method:uri)。可复用的只有凭据来源、
 * nonce 环防重放骨架与常量时间比较纪律——摘要算法本身是第二套实现。
 *
 * 依赖接入面（与 onvif_media_io_t 同款注入模式）：
 *   md5  后端 — 默认 mbedTLS（目标侧）；宿主单元测试注入 stub（test/ 下）；
 *   nonce 源  — 默认 esp_random 填 16B hex32；宿主测试注入确定性序列。
 * 这两个后端一旦注入非 NULL，init 之前的默认绑定被覆盖。
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DIGEST_NONCE_HEX 32 /* 16B 随机数 → 32 hex 字符 */
#define DIGEST_HEX_MAX   33 /* MD5 hex + NUL */
#define DIGEST_RING_SLOTS 8 /* 已发未用 nonce 环：单客户端语义足够 */

typedef struct {
    char nonce[DIGEST_NONCE_HEX + 1];
    char realm[48];
} onvif_digest_challenge_t;

/* 解析 Authorization: Digest 头里的五个字段（引号可选）；缺字段返回 false */
typedef struct {
    char username[32];
    char nonce[DIGEST_NONCE_HEX + 1];
    char uri[128];
    char response[DIGEST_HEX_MAX];
} onvif_digest_auth_t;

/* 可注入后端 */
typedef void (*onvif_digest_md5_fn)(const char *in, size_t len, uint8_t out16[16]);
typedef void (*onvif_digest_nonce_fn)(char out[DIGEST_NONCE_HEX + 1]);

/* 绑定后端（NULL = 目标侧默认 mbedTLS + esp_random）。纯软件无副作用，可反复调。 */
void onvif_digest_bind(onvif_digest_md5_fn md5, onvif_digest_nonce_fn nonce_gen);

/* 生成质询：发新 nonce 入环，拼 WWW-Authenticate 的 value（不含头名）。
 * 返回写入长度（截断安全）。 */
int onvif_digest_challenge(const char *realm, onvif_digest_challenge_t *ch,
                           char *out, size_t out_max);

/* 验证 Authorization 头：nonce 必须是本环发出且未用过（一次性）、
 * response == MD5(HA1:nonce:HA2) 常量时间比对。
 * rc 语义：0=ok；<0 格式/环错（未发过/已用/过期）；>0 凭据错（user/pass/realm）。
 * auth 失败时把用掉的 nonce 退还环中（客户端带新 nc 重试同 nonce 属 RFC 行为，
 * 单客户端一次性语义下直接退回，避免一次输错就作废整轮质询）。 */
int onvif_digest_verify(const char *auth_header, const char *method, const char *uri,
                        const char *user, const char *pass, const char *realm,
                        onvif_digest_auth_t *parsed_out);

/* RFC 2617 §3.5 规范向量自检（user=Mufasa…response=6629fae4…）。
 * 返回 true 才允许开启媒体面鉴权——init 时调用并落标记行。 */
bool onvif_digest_selftest(void);

#ifdef __cplusplus
}
#endif
