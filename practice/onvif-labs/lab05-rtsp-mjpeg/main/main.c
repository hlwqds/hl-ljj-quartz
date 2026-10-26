/*
 * lab05-rtsp-mjpeg — 基座 + 发现面 + SOAP 控制面 + 摘要鉴权 + Media 双操作 + RTSP/RTP 取流。
 *
 * 基座裁剪自 esp32-video-tran 的 factory_demo（SPEC §3）：保留
 * 采集→PPA→硬件 JPEG→双缓冲管线（/stream HTTP 对照面）+ WiFi STA +
 * 串口控制台；UI/LVGL 画布、触摸、USB HID、音频、mmap 资产分区均不在。
 * 启动序列对齐 factory_demo 的 stream-only 形态（RUNBOOK §9 第 3 轮固件）。
 */
#include "factory_console.h"
#include "factory_demo_camera.h"
#include "factory_demo_stream.h"
#include "onvif_disc.h"
#include "onvif_auth.h"
#include "onvif_secrets.h"
#include "onvif_svc.h"
#include "onvif_rtsp.h"

#include "esp_err.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include <inttypes.h>

static const char *TAG = "lab05";

static factory_camera_t s_camera;

void app_main(void)
{
    /* 控制台先建（factory_demo 的内部堆纪律：REPL 任务要在堆还富时创建）。 */
    factory_console_init();

    /* 相机先于 WiFi：共享 I2C 归相机管；disp 传 NULL（无显示形态）。 */
    ESP_ERROR_CHECK(factory_camera_init(&s_camera, NULL));
    esp_err_t cam_ret = factory_camera_start_preview(&s_camera);
    if (cam_ret != ESP_OK) {
        ESP_LOGW(TAG, "camera start failed (%s)", esp_err_to_name(cam_ret));
    }

    ESP_LOGI(TAG, "Free internal DMA before stream init: %" PRIu32 " bytes",
             (uint32_t)heap_caps_get_free_size(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL));
    esp_err_t stream_ret = factory_stream_init();
    if (stream_ret != ESP_OK) {
        ESP_LOGW(TAG, "stream init failed (%s)", esp_err_to_name(stream_ret));
    }
    ESP_LOGI(TAG, "Free internal DMA after stream init: %" PRIu32 " bytes",
             (uint32_t)heap_caps_get_free_size(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL));

    /* 发现面：注册 GOT_IP 监听，拿到地址后起 UDP 3702 应答任务。 */
    ESP_ERROR_CHECK(onvif_disc_init());

    /* 控制面：等基座 httpd 就绪后挂 /onvif/device_service（lab02 交付）。 */
    static const onvif_svc_config_t svc_cfg = {
        .marker = "LAB05",
    .auth = true,
    .users = true,
    .profiles = true,
    .stream_uri = true,
    .profile_s = false,
        .io =
            {
                .httpd = factory_stream_httpd,
                .copy_latest = factory_stream_copy_latest,
                .copy_latest_id = factory_stream_copy_latest_id,
            },
    };
    ESP_ERROR_CHECK(onvif_svc_init(&svc_cfg));

    /* 鉴权与 SNTP：读 NVS 的 sntp 开关并按需启动（lab03 交付）。 */
    ESP_ERROR_CHECK(onvif_auth_init(ONVIF_AUTH_USER, ONVIF_AUTH_PASS));

    /* RTSP/RTP 取流服务：8554 端口（lab05 交付）。 */
    rtsp_server_init(&svc_cfg.io, NULL); /* 历史形态：匿名开放（ch16 §16.2 边界） */

    ESP_LOGI(TAG, "lab05 base ready (camera+stream+disc+svc+auth+media+rtsp)");
}
