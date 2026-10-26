#pragma once

#include <stdbool.h>

#include "esp_err.h"

#include "onvif_media_io.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * onvif_svc 配置面：站点能力开关 + 标记前缀 + 媒体边界。
 *
 * 能力旗标按站裁剪（kOps 在 init 时按旗标装配，未装配的操作走
 * ActionNotSupported 合规拒绝；未引用的模板函数被 gc-sections 裁出固件，
 * 存储账随旗标缩放）：
 *   users      — GetUsers 鉴权靶子（lab03+）
 *   profiles   — GetProfiles + GetSnapshotUri + /onvif-http/snapshot（lab04+）
 *   stream_uri — GetStreamUri（lab05+，rtsp 由独立模块提供取流面）
 *   profile_s  — Profile S 八操作（lab06，ch17 §17.5.1）
 *   profile_g  — Profile G 骨架（ch17 §17.5.5；须同时编译期 ONVIF_PROFILE_G）
 * marker      — $$$ ONVIF <marker> OP 标记前缀（lab02..lab05 各用本站号；
 *               lab06 归位功能来源站传 LAB05，见 ch17 站点标记纪律）
 *
 * io 注入契约（漏配不会在编译期报）：
 *   httpd          — 无条件必填，onvif_svc_init 校验（漏配 → ESP_ERR_INVALID_ARG）；
 *   copy_latest    — 仅 profiles=true 时必填，onvif_svc_init 校验（同上）；
 *   copy_latest_id — RTSP 消费方（stream_uri/profile_s 站）必填，由 rtsp_server_init
 *                    校验（void 返回：漏配只打一行日志并拒启 RTSP，:8554 不监听，
 *                    SOAP 面照常——别指望 svc init 替你抓这条）。
 */
typedef struct {
    const char *marker;
    bool auth;       /* 摘要门（onvif_auth_verify 五环判据链） */
    bool users;
    bool profiles;
    bool stream_uri;
    bool profile_s;
    bool profile_g;
    onvif_media_io_t io; /* profiles/stream_uri/profile_s 任一为真时必填 */
} onvif_svc_config_t;

/**
 * @brief 等 io->httpd() 就绪后注册 /onvif/device_service 等处理器。
 *        阻塞直到 HTTP 服务起来（GOT_IP 由基座负责），故须在流管线 init 后调用。
 */
esp_err_t onvif_svc_init(const onvif_svc_config_t *cfg);

#ifdef __cplusplus
}
#endif
