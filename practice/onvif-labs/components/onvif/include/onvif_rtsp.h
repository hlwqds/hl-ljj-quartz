/*
 * onvif_rtsp.h — 8554 端口 raw socket RTSP 状态机 + RFC 2435 MJPEG/RTP 封包器（lab05）。
 *
 * 单客户端、逐连接串行（SPEC §6）：accept 一次只服务一条连接；信令白名单
 * OPTIONS/DESCRIBE/SETUP/PLAY/TEARDOWN；传输双档（TCP interleaved 优先，UDP 第二档）。
 * 帧源经 onvif_media_io 注入（组件不依赖采集基座）。
 *
 * 媒体面鉴权（ch17 §17.5.3）：站点级开关 + RFC 2617 Digest。
 *   auth=NULL 或 digest=false → 历史形态（lab05 站，匿名开放为明示边界）；
 *   digest=true               → DESCRIBE/SETUP 先 401 质询，凭据复用 onvif_auth
 *                               注入的那一对（单一来源），nonce 一次性防重放。
 */
#pragma once

#include <stdbool.h>

#include "onvif_media_io.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool digest;
    const char *realm; /* 质询域（如 "onvif@korvo-1"）；digest=true 时必填 */
} onvif_rtsp_auth_t;

/* 起监听任务；io->copy_latest_id 为帧源（必填）。 */
void rtsp_server_init(const onvif_media_io_t *io, const onvif_rtsp_auth_t *auth);

#ifdef __cplusplus
}
#endif
