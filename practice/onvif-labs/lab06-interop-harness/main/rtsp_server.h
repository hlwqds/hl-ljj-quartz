/*
 * rtsp_server.h — 8554 端口 raw socket RTSP 状态机 + RFC 2435 MJPEG/RTP 封包器（lab05）。
 *
 * 单客户端、逐连接串行（SPEC §6）：accept 一次只服务一条连接；信令白名单
 * OPTIONS/DESCRIBE/SETUP/PLAY/TEARDOWN；传输双档（TCP interleaved 优先，UDP 第二档）。
 * 无 RTSP Digest、无 RTCP SR——明示边界（ch16 §16.2），凭据接入归 lab06。
 */
#pragma once

void rtsp_server_init(void);
