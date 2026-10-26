/*
 * lab06-interop-harness — 五站总装固件 + witness 标记（互通收口，lab01–lab05 交付全量）。
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
#include "onvif_rtsp.h"
#include "onvif_secrets.h"
#include "onvif_svc.h"

#include "esp_err.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include <inttypes.h>

static const char *TAG = "lab06";

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

    /* 鉴权与 SNTP：凭据留在 app 侧（onvif_secrets.h），组件只收指针（lab03 交付）。 */
    ESP_ERROR_CHECK(onvif_auth_init(ONVIF_AUTH_USER, ONVIF_AUTH_PASS));

    /* 控制面 + 媒体面：总装站全能力开（lab02–05 + Profile S 补齐）；
     * 媒体边界绑基座 factory_stream 三函数（组件不 include 采集头）。 */
    static const onvif_svc_config_t svc_cfg = {
        .marker = "LAB05", /* 标记前缀归位功能来源站（ch17 站点标记纪律） */
        .auth = true,
        .users = true,
        .profiles = true,
        .stream_uri = true,
        .profile_s = true,
        .profile_g = true, /* Profile G 骨架（ch17 §17.5.5） */
        .io =
            {
                .httpd = factory_stream_httpd,
                .copy_latest = factory_stream_copy_latest,
                .copy_latest_id = factory_stream_copy_latest_id,
            },
    };
    ESP_ERROR_CHECK(onvif_svc_init(&svc_cfg));

    /* RTSP/RTP 取流服务：8554 端口（lab05 交付），帧源同一边界注入；
     * 媒体面 Digest 鉴权开（ch17 §17.5.3）——凭据复用 onvif_auth 注入的那对。 */
    static const onvif_rtsp_auth_t rtsp_auth = {
        .digest = true,
        .realm = "onvif@korvo-1",
    };
    rtsp_server_init(&svc_cfg.io, &rtsp_auth);

    ESP_LOGI(TAG, "lab06 base ready (total assembly for interop witness)");
}
