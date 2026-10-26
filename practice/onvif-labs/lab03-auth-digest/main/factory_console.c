/*
 * 串口控制台 — esp_console REPL（UART0，115200）。
 * 自 factory_demo main.c §串口控制台段整体平移：status/ip/heap/restart 四条。
 * lab01 为 stream-only 形态，UI 分支的 stream start/stop 命令不迁移。
 */

#include "factory_console.h"

#include "factory_demo_stream.h"

#include "esp_console.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_system.h"
#include <string.h>
#include <time.h>
#include <sys/time.h>

#include "onvif_auth.h"
#include "onvif_stats.h"
#include "sdkconfig.h"
#include <inttypes.h>

static const char *TAG = "factory_console";

static void factory_console_print_heap(void)
{
    printf("free_dma=%" PRIu32 "\n",
           (uint32_t)heap_caps_get_free_size(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL));
    printf("free_spiram=%" PRIu32 "\n",
           (uint32_t)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
}

static int factory_console_cmd_status(int argc, char **argv)
{
    factory_stream_status_t status = {0};
    factory_stream_get_status(&status);

    printf("frames_encoded=%" PRIu32 "\n", status.frames_encoded);
    printf("frames_sent=%" PRIu32 "\n", status.frames_sent);
    printf("last_jpeg_bytes=%" PRIu32 "\n", status.last_jpeg_bytes);
    printf("avg_encode_ms=%.2f\n", status.avg_encode_ms);
    printf("wifi_rssi=%d\n", status.wifi_rssi);
    printf("ip=%s\n", status.ip[0] ? status.ip : "(not connected)");
    factory_console_print_heap();
    return 0;
}

static int factory_console_cmd_ip(int argc, char **argv)
{
    factory_stream_status_t status = {0};
    factory_stream_get_status(&status);
    printf("ip=%s\n", status.ip[0] ? status.ip : "(not connected)");
    return 0;
}

static int factory_console_cmd_heap(int argc, char **argv)
{
    factory_console_print_heap();
    return 0;
}

/* ch17 §17.5.2：$$$ ONVIF STATS 内存账四层明细 */
static int factory_console_cmd_mem(int argc, char **argv)
{
    onvif_stats_dump();
    return 0;
}

static int factory_console_cmd_restart(int argc, char **argv)
{
    printf("restarting...\n");
    fflush(stdout);
    esp_restart();
    return 0; /* not reached */
}

/* lab03 教学开关：sntp on|off|status（off 重启后板钟停纪元，复现 ch09 坑 1） */
static int factory_console_cmd_sntp(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "on") == 0) {
        onvif_auth_sntp_set(true);
        printf("sntp on\n");
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "off") == 0) {
        onvif_auth_sntp_set(false);
        printf("sntp off\n");
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "status") == 0) {
        printf("sntp=%s\n", onvif_auth_sntp_enabled() ? "on" : "off");
        printf("epoch=%lld\n", (long long)time(NULL));
        return 0;
    }
    printf("usage: sntp on|off|status\n");
    return 1;
}

/* lab03 教学开关：clock reset——settimeofday(0) 把板钟归零（等效 RTC 掉电起步）。
 * 注意 esp_restart() 不清 RTC 墙钟（实测：SNTP 同步过的 2026 时间软重启后保留），
 * 复现 ch09 坑 1 的「板钟停纪元」必须显式归零。 */
static int factory_console_cmd_clock(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "reset") == 0) {
        struct timeval tv = {0, 0};
        settimeofday(&tv, NULL);
        printf("clock reset to epoch (ch09 pit 1 replay)\n");
        return 0;
    }
    printf("usage: clock reset\n");
    return 1;
}

void factory_console_init(void)
{
    esp_console_repl_config_t repl_config = ESP_CONSOLE_REPL_CONFIG_DEFAULT();
    repl_config.prompt = "korvo>";
    repl_config.task_stack_size = 2048;
    repl_config.max_history_len = 8;
    repl_config.max_cmdline_length = 128;

    /* esp_console_new_repl_uart 安装小缓冲 UART 驱动并启动 linenoise REPL
     * 任务——趁内部堆还富时创建（factory_demo 的早建纪律）。 */
    const esp_console_dev_uart_config_t uart_config = {
        .channel = CONFIG_ESP_CONSOLE_UART_NUM,
        .baud_rate = 115200,
        .tx_gpio_num = -1, /* 沿用 bootloader/console 已占用的引脚 */
        .rx_gpio_num = -1,
    };

    esp_console_repl_t *repl = NULL;
    esp_err_t ret = esp_console_new_repl_uart(&uart_config, &repl_config, &repl);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "console REPL create failed (%s)", esp_err_to_name(ret));
        return;
    }

    esp_console_register_help_command();

    const esp_console_cmd_t cmd_status = {
        .command = "status",
        .help = "streaming metrics: frames, jpeg size, encode time, rssi, ip, heap",
        .hint = NULL,
        .func = factory_console_cmd_status,
    };
    const esp_console_cmd_t cmd_ip = {
        .command = "ip",
        .help = "print the station IP address",
        .hint = NULL,
        .func = factory_console_cmd_ip,
    };
    const esp_console_cmd_t cmd_heap = {
        .command = "heap",
        .help = "free internal DMA heap and free SPIRAM",
        .hint = NULL,
        .func = factory_console_cmd_heap,
    };
    const esp_console_cmd_t cmd_restart = {
        .command = "restart",
        .help = "esp_restart() the board",
        .hint = NULL,
        .func = factory_console_cmd_restart,
    };
    const esp_console_cmd_t cmd_sntp = {
        .command = "sntp",
        .help = "SNTP switch (lab03): on|off|status; off survives reboot (ch09 pit 1)",
        .hint = "<on|off|status>",
        .func = factory_console_cmd_sntp,
    };
    const esp_console_cmd_t cmd_clock = {
        .command = "clock",
        .help = "board clock teaching switch (lab03): reset -> epoch (ch09 pit 1)",
        .hint = "<reset>",
        .func = factory_console_cmd_clock,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&cmd_status));
    ESP_ERROR_CHECK(esp_console_cmd_register(&cmd_ip));
    ESP_ERROR_CHECK(esp_console_cmd_register(&cmd_heap));
    ESP_ERROR_CHECK(esp_console_cmd_register(&cmd_restart));
    const esp_console_cmd_t cmd_mem = {
        .command = "mem",
        .help = "onvif memory ledger: per-module static/heap + heap snapshot",
        .hint = NULL,
        .func = factory_console_cmd_mem,
    };
    ESP_ERROR_CHECK(esp_console_cmd_register(&cmd_mem));
    ESP_ERROR_CHECK(esp_console_cmd_register(&cmd_sntp));
    ESP_ERROR_CHECK(esp_console_cmd_register(&cmd_clock));

    ESP_ERROR_CHECK(esp_console_start_repl(repl));
    ESP_LOGI(TAG, "serial console ready (status/ip/heap/restart/sntp/clock, help lists all)");
}
