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
 * marker      — $$$ ONVIF <marker> OP 标记前缀（lab02..lab05 各用本站号；
 *               lab06 归位功能来源站传 LAB05，见 ch17 站点标记纪律）
 *
 * io 注入契约（按需三条，漏配 → init 返回 ESP_ERR_INVALID_ARG，编译期不报）：
 *   httpd          — 无条件必填（/onvif/device_service 每站都挂基座 80 端口）；
 *   copy_latest    — 仅 profiles=true 时必填（快照处理器取帧）；
 *   copy_latest_id — 仅 stream_uri/profile_s 且使用组件 RTSP 时必填（帧号去重取帧）。
 */
typedef struct {
    const char *marker;
    bool auth;       /* 摘要门（onvif_auth_verify 五环判据链） */
    bool users;
    bool profiles;
    bool stream_uri;
    bool profile_s;
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
