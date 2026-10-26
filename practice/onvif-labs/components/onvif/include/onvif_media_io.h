/*
 * onvif_media_io.h — ONVIF 组件与采集管线（factory_stream）的唯一边界。
 *
 * 依赖倒置：组件不 include 任何 app/bsp 头；宿主应用在 onvif_svc_init /
 * rtsp_server_init 时注入三个函数指针（lab 站点均直接绑 factory_stream_*）。
 * 组件可独立于采集基座编译与单测。
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "esp_http_server.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    /* /onvif/ 前缀 URI 要挂上去的 80 端口 httpd 实例（GOT_IP 后非 NULL） */
    httpd_handle_t (*httpd)(void);
    /* 拷贝最新成品 JPEG；返回字节数，首帧未就绪或 dst_max 不足返回 -1 */
    ssize_t (*copy_latest)(uint8_t *dst, size_t dst_max);
    /* 带帧号变体（RTSP 消费者去重用）：*frame_id 收拷贝时刻的 frames_encoded */
    ssize_t (*copy_latest_id)(uint8_t *dst, size_t dst_max, uint32_t *frame_id);
} onvif_media_io_t;

#ifdef __cplusplus
}
#endif
