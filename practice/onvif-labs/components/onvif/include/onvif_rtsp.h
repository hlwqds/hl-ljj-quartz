/*
 * onvif_rtsp.h — 8554 端口 raw socket RTSP 状态机 + RFC 2435 MJPEG/RTP 封包器（lab05）。
 *
 * 单客户端、逐连接串行（SPEC §6）：accept 一次只服务一条连接；信令白名单
 * OPTIONS/DESCRIBE/SETUP/PLAY/TEARDOWN；传输双档（TCP interleaved 优先，UDP 第二档）。
 * 无 RTSP Digest、无 RTCP SR——明示边界（ch16 §16.2）。
 * 帧源经 onvif_media_io 注入（组件不依赖采集基座）。
 */
#pragma once

#include "onvif_media_io.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 起监听任务；io->copy_latest_id 为帧源（必填）。 */
void rtsp_server_init(const onvif_media_io_t *io);

#ifdef __cplusplus
}
#endif
