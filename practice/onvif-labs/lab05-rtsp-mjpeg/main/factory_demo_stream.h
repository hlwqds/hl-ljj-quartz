/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#pragma once

#include <stdint.h>
#include "bsp/esp32_s31_korvo.h"
#include "esp_err.h"
#include "esp_http_server.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Snapshot of the streaming metrics (also served by GET /status).
 */
typedef struct {
    uint32_t frames_encoded;    /*!< frames pushed through the hardware JPEG encoder */
    uint32_t frames_sent;       /*!< JPEG parts delivered to /stream clients */
    uint32_t last_jpeg_bytes;   /*!< byte size of the newest JPEG frame */
    double avg_encode_ms;       /*!< average PPA + JPEG encode time per frame, in ms */
    int wifi_rssi;              /*!< station RSSI in dBm, 0 when not associated */
    char ip[16];                /**< station IP, empty string when not connected */
} factory_stream_status_t;

/**
 * @brief 80 端口 MJPEG httpd 实例句柄（GOT_IP 后就绪；未起时返回 NULL）。
 *        供 onvif_svc 在同一实例上挂 /onvif/ 前缀 URI（SPEC §5：SOAP 与对照面同端口）。
 */
httpd_handle_t factory_stream_httpd(void);

/**
 * @brief 拷贝最新成品 JPEG（lab04：快照与后续 RTP 消费者共用）。
 *        锁内只拷贝 read_slot，不碰 frame_sem（/stream 订阅者的唤醒信号）。
 *        @return 拷贝字节数；首帧未就绪或 dst_max 不足返回 -1。
 */
ssize_t factory_stream_copy_latest(uint8_t *dst, size_t dst_max);

/**
 * @brief 带 frame_id 的拷贝变体（lab05：RTSP 消费者用它做去重——同一帧不重发）。
 *        @return 同 copy_latest；*frame_id 收到拷贝时刻的 frames_encoded 计数。
 *        多消费者（RTSP 等）用「轮询 + frame_id 去重」，勿 wait frame_sem。
 */
ssize_t factory_stream_copy_latest_id(uint8_t *dst, size_t dst_max, uint32_t *frame_id);

/**
 * @brief Fill a snapshot of the streaming metrics, safe from any task.
 */
void factory_stream_get_status(factory_stream_status_t *out);

/**
 * @brief Bring up WiFi STA and the MJPEG streaming pipeline.
 *
 * Allocates the hardware JPEG encoder, the PPA color conversion client and
 * their PSRAM buffers, then starts the WiFi station asynchronously so the
 * factory UI boot is not blocked. The HTTP servers are started from the
 * IP_EVENT_STA_GOT_IP handler once an address is available.
 *
 * @return ESP_OK on success, otherwise an ESP-IDF error code.
 */
esp_err_t factory_stream_init(void);

/**
 * @brief Encode and publish one camera frame (latest-frame semantics).
 *
 * Called inline from the camera frame loop between preview rendering and
 * bsp_camera_return_frame(). Converts the frame to RGB565 with PPA, encodes
 * it with the hardware JPEG engine and publishes it as the newest frame for
 * the HTTP stream subscribers. Slow subscribers simply skip frames.
 */
void factory_stream_submit_frame(const bsp_camera_format_t *format, const bsp_camera_frame_t *frame);

#ifdef __cplusplus
}
#endif
