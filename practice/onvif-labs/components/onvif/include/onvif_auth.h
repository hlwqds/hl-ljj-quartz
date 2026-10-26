/*
 * onvif_auth.h — WS-Security UsernameToken 摘要认证 + SNTP 时钟纪律（lab03）。
 *
 * 判据链（顺序即排错大纲，ch14 §14.2）：查用户 → nonce 解码 → SHA1 重算比对（常量
 * 时间） → Created ±300s 窗口 → nonce 环重放拒绝。对外统一 ter:NotAuthorized，
 * 分因落板端 $$$ 标记行（AUTH ok/deny reason=...）。
 * 凭据由宿主应用注入（onvif_secrets.h 留在 app 侧，gitignore 纪律不进组件）。
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

typedef enum {
    AUTH_OK = 0,
    AUTH_NO_TOKEN,        /* 没带 Security 头 */
    AUTH_BAD_TOKEN,       /* nonce 非 base64 / 超上限；Created 解析不了或不支持形态 */
    AUTH_USER_UNKNOWN,    /* 用户名不存在（与错口令同拒，防枚举） */
    AUTH_DIGEST_MISMATCH, /* 口令错 / 字节观错（nonce 拼了 base64 文本等） */
    AUTH_CLOCK_SKEW,      /* Created 出 ±300s 窗口（ch09 坑 1） */
    AUTH_NONCE_REPLAY,    /* 窗口内重放同一报文 */
} auth_rc_t;

/* 注入凭据、读 NVS 的 sntp 开关并按需启动 SNTP；打 AUTH READY 标记行。
 * 须在 NVS 初始化后调用；user/pass 须指向静态生存期字符串。 */
esp_err_t onvif_auth_init(const char *user, const char *pass);

/* 对整份 SOAP 请求原文跑五环判据链；ok/deny 标记行在本函数内落日志。 */
auth_rc_t onvif_auth_verify(const char *rx);

/* 失败码 → run.log reason 字符串（user_unknown/bad_token/digest_mismatch/...） */
const char *onvif_auth_reason(auth_rc_t rc);

/* 教学开关：sntp on|off，落 NVS 重启保持；开时立即发起一轮同步（回调打 SNTP synced）。 */
void onvif_auth_sntp_set(bool enable);
bool onvif_auth_sntp_enabled(void);

/* 花名册唯一用户（init 注入；GetUsers 应答与 AUTH 标记行共用） */
const char *onvif_auth_username(void);
