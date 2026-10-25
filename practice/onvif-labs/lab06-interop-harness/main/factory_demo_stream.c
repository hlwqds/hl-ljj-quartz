/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * WiFi STA + MJPEG HTTP streaming service (wireless video link, stage 2).
 *
 * Pipeline (all inline in the camera frame loop, see factory_camera_task):
 *   UYVY frame --PPA SRM--> RGB565 --HW JPEG--> latest-frame double buffer
 *                                      |
 *   httpd /stream (multipart/x-mixed-replace) reads the newest JPEG, slow
 *   subscribers simply drop frames.
 *
 * Two httpd instances are used on purpose: the esp_http_server processes
 * requests in a single task, so the never-ending /stream handler would
 * starve /status if both lived on the same server (same trick as the
 * esp32-camera http examples):
 *   port 80: GET /        minimal viewer page (img tag -> /stream)
 *            GET /stream  multipart MJPEG stream
 *   port 81: GET /status  plain text metrics for stage acceptance
 */

#include "factory_demo_stream.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include "driver/jpeg_encode.h"
#include "driver/ppa.h"
#include "esp_check.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_memory_utils.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "linux/videodev2.h"
#include "nvs_flash.h"
#include "wifi_secrets.h"

#define FACTORY_STREAM_TAG                 "factory_stream"

/* Encoder input: 640x480 RGB565 is exactly 614400 bytes (600 KiB). */
#define FACTORY_STREAM_RGB_BUF_SIZE        (600 * 1024)
/* Encoder output plus the /stream send buffer keep one full JPEG each. */
#define FACTORY_STREAM_JPEG_BUF_SIZE       (300 * 1024)
#define FACTORY_STREAM_JPEG_QUALITY        80
/* Encode every Nth camera frame (1 = every frame, sensor caps at 15 fps). */
#define FACTORY_STREAM_FRAME_DIV           1
#define FACTORY_STREAM_FRAME_TIMEOUT_MS    5000
#define FACTORY_STREAM_PPA_ALIGN           64
#define FACTORY_STREAM_HTTP_PORT           80
#define FACTORY_STREAM_STATUS_PORT         81
#define FACTORY_STREAM_BOUNDARY            "factorystream"

static const char *TAG = FACTORY_STREAM_TAG;

static const char s_stream_boundary[] = "\r\n--" FACTORY_STREAM_BOUNDARY "\r\n";
static const char s_stream_content_type[] =
    "multipart/x-mixed-replace;boundary=" FACTORY_STREAM_BOUNDARY;

typedef struct {
    SemaphoreHandle_t lock;        /* protects the slots below and the counters */
    SemaphoreHandle_t frame_sem;   /* given once per encoded frame (latest-frame wakeup) */
    jpeg_encoder_handle_t jpeg_enc;
    ppa_client_handle_t ppa;
    uint8_t *rgb_buf;              /* PPA output / JPEG input, DMA capable PSRAM */
    size_t rgb_buf_size;
    uint8_t *jpeg_buf[2];          /* double buffer, DMA capable PSRAM */
    size_t jpeg_buf_size[2];
    uint8_t *send_buf;             /* httpd task local copy of the newest JPEG */
    size_t send_buf_size;
    httpd_handle_t httpd;          /* port 80: / and /stream */
    httpd_handle_t httpd_status;   /* port 81: /status */
    volatile bool ready;           /* encoder + buffers allocated */
    volatile bool active;          /* first IP acquired, encode incoming frames */
    volatile bool wifi_started;    /* esp_wifi_start() succeeded: WiFi APIs are safe to call */
    uint8_t write_slot;            /* slot the next encode writes into */
    uint8_t read_slot;             /* slot holding the newest complete JPEG */
    size_t read_size;              /* byte size of the newest complete JPEG */
    /* Metrics reported by /status */
    uint32_t frames_encoded;
    uint32_t frames_sent;
    uint32_t last_jpeg_bytes;
    uint64_t total_encode_us;
    char ip[16];
} factory_stream_t;

static factory_stream_t s_stream = {
    .httpd = NULL,
    .httpd_status = NULL,
};

static size_t factory_stream_align_up(size_t size, size_t align)
{
    return (size + align - 1) & ~(align - 1);
}

/* ------------------------------------------------------------------ */
/* Camera side: UYVY -> RGB565 -> JPEG, publish as latest frame        */
/* ------------------------------------------------------------------ */

void factory_stream_submit_frame(const bsp_camera_format_t *format, const bsp_camera_frame_t *frame)
{
    if (!s_stream.ready || !s_stream.active) {
        return;
    }
    if (!format || !frame || !frame->data) {
        return;
    }

    /* Frame decimation for the encoder. */
    static uint32_t s_seq = 0;
    if ((++s_seq % FACTORY_STREAM_FRAME_DIV) != 0) {
        return;
    }

    static bool s_format_logged = false;
    const uint32_t packed_stride = format->width * 2; /* UYVY and RGB565 are both 2 bytes per pixel */
    ppa_srm_color_mode_t in_color_mode;
    bool byte_swap = false;

    if (format->pixelformat == V4L2_PIX_FMT_UYVY) {
        in_color_mode = PPA_SRM_COLOR_MODE_YUV422_UYVY;
    } else if (format->pixelformat == V4L2_PIX_FMT_RGB565) {
        in_color_mode = PPA_SRM_COLOR_MODE_RGB565;
    } else if (format->pixelformat == V4L2_PIX_FMT_RGB565X) {
        in_color_mode = PPA_SRM_COLOR_MODE_RGB565;
        byte_swap = true;
    } else {
        if (!s_format_logged) {
            ESP_LOGW(TAG, "Unsupported stream pixel format fourcc=%c%c%c%c, streaming disabled",
                     (char)(format->pixelformat & 0xff),
                     (char)((format->pixelformat >> 8) & 0xff),
                     (char)((format->pixelformat >> 16) & 0xff),
                     (char)((format->pixelformat >> 24) & 0xff));
            s_format_logged = true;
        }
        return;
    }

    /* The PPA input has no stride field, only packed rows are supported.
     * The JPEG driver reads RGB565, so the sensor data must be converted first. */
    if (format->bytesperline && format->bytesperline != packed_stride) {
        if (!s_format_logged) {
            ESP_LOGW(TAG, "Unsupported stream stride %"PRIu32" (packed %"PRIu32"), streaming disabled",
                     format->bytesperline, packed_stride);
            s_format_logged = true;
        }
        return;
    }

    /* Full frame, no crop, scale 1.0: UYVY -> RGB565 into the JPEG input buffer. */
    const size_t rgb_size = (size_t)format->width * format->height * 2;
    const size_t rgb_size_aligned = factory_stream_align_up(rgb_size, FACTORY_STREAM_PPA_ALIGN);
    if (rgb_size_aligned > s_stream.rgb_buf_size) {
        if (!s_format_logged) {
            ESP_LOGW(TAG, "Frame %"PRIu32"x%"PRIu32" needs %zu bytes, buffer holds %zu, streaming disabled",
                     format->width, format->height, rgb_size_aligned, s_stream.rgb_buf_size);
            s_format_logged = true;
        }
        return;
    }

    const int64_t encode_start = esp_timer_get_time();

    ppa_srm_oper_config_t srm_config = {
        .in = {
            .buffer = frame->data,
            .pic_w = format->width,
            .pic_h = format->height,
            .block_w = format->width,
            .block_h = format->height,
            .block_offset_x = 0,
            .block_offset_y = 0,
            .srm_cm = in_color_mode,
            .yuv_range = PPA_COLOR_RANGE_FULL,
            .yuv_std = PPA_COLOR_CONV_STD_RGB_YUV_BT601,
        },
        .out = {
            .buffer = s_stream.rgb_buf,
            .buffer_size = rgb_size_aligned,
            .pic_w = format->width,
            .pic_h = format->height,
            .block_offset_x = 0,
            .block_offset_y = 0,
            .srm_cm = PPA_SRM_COLOR_MODE_RGB565,
        },
        .rotation_angle = PPA_SRM_ROTATION_ANGLE_0,
        .scale_x = 1.0f,
        .scale_y = 1.0f,
        .byte_swap = byte_swap,
        .mode = PPA_TRANS_MODE_BLOCKING,
    };
    esp_err_t ret = ppa_do_scale_rotate_mirror(s_stream.ppa, &srm_config);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "PPA UYVY->RGB565 failed (%s)", esp_err_to_name(ret));
        return;
    }

    /* Despite the enum name, JPEG_ENCODE_IN_FORMAT_YUV422 is actually YVYU
     * while the sensor outputs UYVY, so the frame is fed as RGB565 instead. */
    jpeg_encode_cfg_t encode_config = {
        .src_type = JPEG_ENCODE_IN_FORMAT_RGB565,
        .sub_sample = JPEG_DOWN_SAMPLING_YUV422,
        .image_quality = FACTORY_STREAM_JPEG_QUALITY,
        .width = format->width,
        .height = format->height,
        .pixel_reverse = false,
    };
    uint8_t *jpeg_dst = s_stream.jpeg_buf[s_stream.write_slot];
    uint32_t jpeg_size = 0;
    ret = jpeg_encoder_process(s_stream.jpeg_enc, &encode_config,
                               s_stream.rgb_buf, rgb_size,
                               jpeg_dst, s_stream.jpeg_buf_size[s_stream.write_slot],
                               &jpeg_size);
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "JPEG encode failed (%s)", esp_err_to_name(ret));
        return;
    }

    const int64_t encode_end = esp_timer_get_time();

    xSemaphoreTake(s_stream.lock, portMAX_DELAY);
    s_stream.read_slot = s_stream.write_slot;
    s_stream.read_size = jpeg_size;
    s_stream.frames_encoded++;
    s_stream.last_jpeg_bytes = jpeg_size;
    s_stream.total_encode_us += (uint64_t)(encode_end - encode_start);
    xSemaphoreGive(s_stream.lock);
    s_stream.write_slot ^= 1;

    /* Latest-frame semantics: subscribers wake up and take the newest JPEG. */
    xSemaphoreGive(s_stream.frame_sem);
}

ssize_t factory_stream_copy_latest(uint8_t *dst, size_t dst_max)
{
    /* 锁内只拷贝 read_slot 最新成品 JPEG，不做任何编码/换算；不碰 frame_sem。 */
    if (dst == NULL || dst_max == 0 || s_stream.lock == NULL) {
        return -1; /* lock NULL：factory_stream_init 未跑成（main.c 只告警不阻断） */
    }
    xSemaphoreTake(s_stream.lock, portMAX_DELAY);
    const size_t n = s_stream.read_size;
    if (n == 0 || n > dst_max) {
        xSemaphoreGive(s_stream.lock);
        return -1;
    }
    memcpy(dst, s_stream.jpeg_buf[s_stream.read_slot], n);
    xSemaphoreGive(s_stream.lock);
    return (ssize_t)n;
}

ssize_t factory_stream_copy_latest_id(uint8_t *dst, size_t dst_max, uint32_t *frame_id)
{
    if (dst == NULL || dst_max == 0 || s_stream.lock == NULL) {
        return -1;
    }
    xSemaphoreTake(s_stream.lock, portMAX_DELAY);
    const size_t n = s_stream.read_size;
    if (frame_id != NULL) {
        *frame_id = s_stream.frames_encoded;
    }
    if (n == 0 || n > dst_max) {
        xSemaphoreGive(s_stream.lock);
        return -1;
    }
    memcpy(dst, s_stream.jpeg_buf[s_stream.read_slot], n);
    xSemaphoreGive(s_stream.lock);
    return (ssize_t)n;
}

/* 注意：RTSP 等多消费者请勿 wait frame_sem（二值信号量谁取谁消费，会偷走 /stream
 * 订阅者的唤醒）——按 copy_latest_id 轮询 + frame_id 去重（lab05 rtsp_server 的做法）。 */

/* ------------------------------------------------------------------ */
/* HTTP handlers                                                       */
/* ------------------------------------------------------------------ */

static esp_err_t factory_stream_http_index(httpd_req_t *req)
{
    httpd_resp_set_type(req, "text/html");
    return httpd_resp_send(req,
                           "<!DOCTYPE html><html><head><title>factory_stream</title></head>"
                           "<body style=\"margin:0;background:#000;text-align:center\">"
                           "<img src=\"/stream\" style=\"max-width:100%;height:auto\" alt=\"stream\">"
                           "</body></html>",
                           HTTPD_RESP_USE_STRLEN);
}

/* Fixed reserve at the front of the send buffer for the per-frame multipart
 * prefix (boundary + part header), so the whole part goes out in ONE chunk.
 * Three small writes per frame hit the classic Nagle + delayed-ACK stall and
 * capped the delivered rate at ~13.9 fps while the encoder runs at 16.7. */
#define FACTORY_STREAM_PART_PREFIX_RESERVE  96

static esp_err_t factory_stream_http_stream(httpd_req_t *req)
{
    ESP_LOGI(TAG, "Stream client connected");
    httpd_resp_set_type(req, s_stream_content_type);
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");

    while (true) {
        size_t jpeg_size = 0;

        /* Wait for the newest frame; on timeout push an empty boundary so
         * idle connections (camera stalled, no client interest) stay alive. */
        if (xSemaphoreTake(s_stream.frame_sem, pdMS_TO_TICKS(FACTORY_STREAM_FRAME_TIMEOUT_MS)) == pdTRUE) {
            xSemaphoreTake(s_stream.lock, portMAX_DELAY);
            jpeg_size = s_stream.read_size;
            if (jpeg_size + FACTORY_STREAM_PART_PREFIX_RESERVE > s_stream.send_buf_size) {
                jpeg_size = 0;
            }
            if (jpeg_size) {
                memcpy(s_stream.send_buf + FACTORY_STREAM_PART_PREFIX_RESERVE,
                       s_stream.jpeg_buf[s_stream.read_slot], jpeg_size);
            }
            xSemaphoreGive(s_stream.lock);
        }

        if (jpeg_size == 0) {
            if (httpd_resp_send_chunk(req, s_stream_boundary, sizeof(s_stream_boundary) - 1) != ESP_OK) {
                break;
            }
            continue;
        }

        int prefix_len = snprintf((char *)s_stream.send_buf, FACTORY_STREAM_PART_PREFIX_RESERVE,
                                  "\r\n--" FACTORY_STREAM_BOUNDARY "\r\n"
                                  "Content-Type: image/jpeg\r\nContent-Length: %zu\r\n\r\n",
                                  jpeg_size);
        if (prefix_len <= 0 || (size_t)prefix_len >= FACTORY_STREAM_PART_PREFIX_RESERVE) {
            continue;
        }

        if (httpd_resp_send_chunk(req, (const char *)s_stream.send_buf,
                                  (ssize_t)(prefix_len + jpeg_size)) != ESP_OK) {
            break;
        }

        xSemaphoreTake(s_stream.lock, portMAX_DELAY);
        s_stream.frames_sent++;
        xSemaphoreGive(s_stream.lock);
    }

    ESP_LOGI(TAG, "Stream client disconnected");
    return ESP_OK;
}

void factory_stream_get_status(factory_stream_status_t *out)
{
    if (!out) {
        return;
    }

    /* In UI mode factory_stream_init() has not run yet: the module statics
     * are all zero (lock == NULL). Report an empty snapshot instead of
     * touching a NULL mutex. */
    if (!s_stream.lock) {
        memset(out, 0, sizeof(*out));
        return;
    }

    uint64_t total_encode_us = 0;
    xSemaphoreTake(s_stream.lock, portMAX_DELAY);
    out->frames_encoded = s_stream.frames_encoded;
    out->frames_sent = s_stream.frames_sent;
    out->last_jpeg_bytes = s_stream.last_jpeg_bytes;
    total_encode_us = s_stream.total_encode_us;
    strlcpy(out->ip, s_stream.ip, sizeof(out->ip));
    xSemaphoreGive(s_stream.lock);

    out->avg_encode_ms = out->frames_encoded ?
                         (double)total_encode_us / 1000.0 / (double)out->frames_encoded : 0.0;

    /* esp_wifi_sta_get_ap_info() crashes when the WiFi stack was never
     * started (UI mode before the stream switch), so gate it. */
    out->wifi_rssi = 0;
    if (s_stream.wifi_started) {
        wifi_ap_record_t ap_info;
        if (esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK) {
            out->wifi_rssi = ap_info.rssi;
        }
    }
}

static esp_err_t factory_stream_http_status(httpd_req_t *req)
{
    factory_stream_status_t status = {0};
    factory_stream_get_status(&status);

    char body[320];
    int len = snprintf(body, sizeof(body),
                       "frames_encoded=%"PRIu32"\n"
                       "frames_sent=%"PRIu32"\n"
                       "last_jpeg_bytes=%"PRIu32"\n"
                       "avg_encode_ms=%.2f\n"
                       "wifi_rssi=%d\n"
                       "ip=%s\n",
                       status.frames_encoded, status.frames_sent, status.last_jpeg_bytes,
                       status.avg_encode_ms, status.wifi_rssi, status.ip);
    if (len <= 0) {
        return ESP_FAIL;
    }

    httpd_resp_set_type(req, "text/plain");
    return httpd_resp_send(req, body, len);
}

static esp_err_t factory_stream_register_uris(void)
{
    const httpd_uri_t index_uri = {
        .uri = "/",
        .method = HTTP_GET,
        .handler = factory_stream_http_index,
    };
    const httpd_uri_t stream_uri = {
        .uri = "/stream",
        .method = HTTP_GET,
        .handler = factory_stream_http_stream,
    };
    const httpd_uri_t status_uri = {
        .uri = "/status",
        .method = HTTP_GET,
        .handler = factory_stream_http_status,
    };

    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_stream.httpd, &index_uri),
                        TAG, "register / failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_stream.httpd, &stream_uri),
                        TAG, "register /stream failed");
    ESP_RETURN_ON_ERROR(httpd_register_uri_handler(s_stream.httpd_status, &status_uri),
                        TAG, "register /status failed");
    return ESP_OK;
}

static esp_err_t factory_stream_http_start(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = FACTORY_STREAM_HTTP_PORT;
    config.ctrl_port += 1; /* keep control ports of the two instances distinct */
    config.stack_size = 8192;
    /* lab04：基座 / + /stream 之外，onvif_svc 还要挂 device POST/GET、media POST/GET、
     * snapshot GET 共 5 个处理器（9 = 2 + 5 + 余量）。 */
    config.max_uri_handlers = 9;
    config.send_wait_timeout = 5;
    config.recv_wait_timeout = 5;
    esp_err_t ret = httpd_start(&s_stream.httpd, &config);
    ESP_RETURN_ON_ERROR(ret, TAG, "start httpd on port %d failed", FACTORY_STREAM_HTTP_PORT);

    httpd_config_t status_config = HTTPD_DEFAULT_CONFIG();
    status_config.server_port = FACTORY_STREAM_STATUS_PORT;
    status_config.ctrl_port += 2;
    status_config.stack_size = 4096;
    status_config.max_uri_handlers = 2;
    ret = httpd_start(&s_stream.httpd_status, &status_config);
    if (ret != ESP_OK) {
        httpd_stop(s_stream.httpd);
        s_stream.httpd = NULL;
        ESP_RETURN_ON_ERROR(ret, TAG, "start status httpd on port %d failed", FACTORY_STREAM_STATUS_PORT);
    }

    ESP_RETURN_ON_ERROR(factory_stream_register_uris(), TAG, "register uri handlers failed");
    return ESP_OK;
}

httpd_handle_t factory_stream_httpd(void)
{
    return s_stream.httpd;
}

/* ------------------------------------------------------------------ */
/* WiFi STA                                                            */
/* ------------------------------------------------------------------ */

static void factory_stream_wifi_event_handler(void *arg, esp_event_base_t event_base,
                                              int32_t event_id, void *event_data)
{
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        const wifi_event_sta_disconnected_t *disconnected =
            (const wifi_event_sta_disconnected_t *)event_data;
        /* Reason codes seen with wrong credentials / missing AP:
         * 15=4-way handshake timeout, 201=no AP found, 202=auth failed. */
        ESP_LOGW(TAG, "WiFi disconnected, reason=%d, retrying", disconnected->reason);
        esp_wifi_connect();
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *event = (const ip_event_got_ip_t *)event_data;

        xSemaphoreTake(s_stream.lock, portMAX_DELAY);
        snprintf(s_stream.ip, sizeof(s_stream.ip), IPSTR, IP2STR(&event->ip_info.ip));
        xSemaphoreGive(s_stream.lock);

        /* Start encoding only once an address is there; the stream handlers
         * and the status page need the servers, and they need the IP. */
        s_stream.active = true;
        if (!s_stream.httpd && factory_stream_http_start() == ESP_OK) {
            ESP_LOGI(TAG, "MJPEG stream at http://%s/stream", s_stream.ip);
            ESP_LOGI(TAG, "status page at http://%s:%d/status", s_stream.ip, FACTORY_STREAM_STATUS_PORT);
        }
    }
}

esp_err_t factory_stream_init(void)
{
    ESP_LOGI(TAG, "heap before stream init: free DMA=%zu, SPIRAM=%zu",
             heap_caps_get_free_size(MALLOC_CAP_DMA), heap_caps_get_free_size(MALLOC_CAP_SPIRAM));

    s_stream.lock = xSemaphoreCreateMutex();
    s_stream.frame_sem = xSemaphoreCreateBinary();
    ESP_RETURN_ON_FALSE(s_stream.lock && s_stream.frame_sem, ESP_ERR_NO_MEM, TAG, "stream sync objects alloc failed");

    /* JPEG encoder working buffers: DMA capable and cache line aligned PSRAM,
     * allocated through the JPEG driver helper. Input 600 KiB, output 2 x 300 KiB. */
    const jpeg_encode_memory_alloc_cfg_t input_alloc = {
        .buffer_direction = JPEG_ENC_ALLOC_INPUT_BUFFER,
    };
    s_stream.rgb_buf = jpeg_alloc_encoder_mem(FACTORY_STREAM_RGB_BUF_SIZE, &input_alloc, &s_stream.rgb_buf_size);
    ESP_RETURN_ON_FALSE(s_stream.rgb_buf, ESP_ERR_NO_MEM, TAG, "RGB565 encode buffer alloc failed");

    const jpeg_encode_memory_alloc_cfg_t output_alloc = {
        .buffer_direction = JPEG_ENC_ALLOC_OUTPUT_BUFFER,
    };
    for (int i = 0; i < 2; i++) {
        s_stream.jpeg_buf[i] = jpeg_alloc_encoder_mem(FACTORY_STREAM_JPEG_BUF_SIZE, &output_alloc,
                                                      &s_stream.jpeg_buf_size[i]);
        ESP_RETURN_ON_FALSE(s_stream.jpeg_buf[i], ESP_ERR_NO_MEM, TAG, "JPEG output buffer %d alloc failed", i);
    }

    /* Plain PSRAM copy target for the httpd task (no DMA requirement). */
    s_stream.send_buf = heap_caps_calloc(1, FACTORY_STREAM_JPEG_BUF_SIZE, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    ESP_RETURN_ON_FALSE(s_stream.send_buf, ESP_ERR_NO_MEM, TAG, "stream send buffer alloc failed");
    s_stream.send_buf_size = FACTORY_STREAM_JPEG_BUF_SIZE;

    const jpeg_encode_engine_cfg_t engine_config = {
        .timeout_ms = 1000, /* one 640x480 frame takes far less than a 15 fps slot */
    };
    ESP_RETURN_ON_ERROR(jpeg_new_encoder_engine(&engine_config, &s_stream.jpeg_enc),
                        TAG, "create JPEG encoder engine failed");

    const ppa_client_config_t ppa_config = {
        .oper_type = PPA_OPERATION_SRM,
        .max_pending_trans_num = 1,
    };
    ESP_RETURN_ON_ERROR(ppa_register_client(&ppa_config, &s_stream.ppa),
                        TAG, "register stream PPA SRM client failed");

    /* Confirm the JPEG working buffers really landed in PSRAM, not internal RAM. */
    ESP_LOGI(TAG, "encode buffers: rgb=%p(ext_ram=%d) jpeg0=%p(ext_ram=%d) jpeg1=%p(ext_ram=%d)",
             s_stream.rgb_buf, esp_ptr_external_ram(s_stream.rgb_buf),
             s_stream.jpeg_buf[0], esp_ptr_external_ram(s_stream.jpeg_buf[0]),
             s_stream.jpeg_buf[1], esp_ptr_external_ram(s_stream.jpeg_buf[1]));
    ESP_LOGI(TAG, "heap after encoder+PPA init: free DMA=%zu, SPIRAM=%zu",
             heap_caps_get_free_size(MALLOC_CAP_DMA), heap_caps_get_free_size(MALLOC_CAP_SPIRAM));

    s_stream.ready = true;

    /* Standard STA bring-up: NVS, netif, default event loop, then connect.
     * esp_wifi_start() is asynchronous, so app_main keeps booting the UI. */
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_RETURN_ON_ERROR(nvs_flash_erase(), TAG, "NVS erase failed");
        ESP_RETURN_ON_ERROR(nvs_flash_init(), TAG, "NVS init failed");
    } else if (ret != ESP_OK) {
        ESP_RETURN_ON_ERROR(ret, TAG, "NVS init failed");
    }

    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "netif init failed");
    ret = esp_event_loop_create_default();
    if (ret != ESP_OK && ret != ESP_ERR_INVALID_STATE) {
        ESP_RETURN_ON_ERROR(ret, TAG, "default event loop create failed");
    }
    ESP_RETURN_ON_FALSE(esp_netif_create_default_wifi_sta(), ESP_FAIL, TAG, "create default wifi sta failed");

    const wifi_init_config_t wifi_init_config = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&wifi_init_config), TAG, "wifi init failed");

    ESP_RETURN_ON_ERROR(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                            factory_stream_wifi_event_handler, NULL, NULL),
                        TAG, "register WIFI_EVENT handler failed");
    ESP_RETURN_ON_ERROR(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                            factory_stream_wifi_event_handler, NULL, NULL),
                        TAG, "register IP_EVENT handler failed");

    /* esp_wifi_set_config takes a non-const pointer, so no const here. */
    wifi_config_t wifi_config = {
        .sta = {
            .ssid = WIFI_SSID,
            .password = WIFI_PASS,
            .threshold.authmode = WIFI_AUTH_WPA2_PSK,
        },
    };
    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_STA), TAG, "wifi set mode failed");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_STA, &wifi_config), TAG, "wifi set config failed");
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "wifi start failed");
    /* Modem-sleep gates TX on DTIM wakeups and adds tens of ms jitter to
     * the stream; a mains-powered video sender prefers throughput. */
    esp_err_t ps_ret = esp_wifi_set_ps(WIFI_PS_NONE);
    if (ps_ret != ESP_OK) {
        ESP_LOGW(TAG, "disable wifi power save failed (%s)", esp_err_to_name(ps_ret));
    }
    s_stream.wifi_started = true;

    ESP_LOGI(TAG, "heap after wifi start: free DMA=%zu, SPIRAM=%zu",
             heap_caps_get_free_size(MALLOC_CAP_DMA), heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
    ESP_LOGI(TAG, "stream service initialized, WiFi STA connecting");
    return ESP_OK;
}
