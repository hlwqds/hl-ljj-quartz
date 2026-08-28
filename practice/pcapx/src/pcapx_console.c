/*
 * pcapx_console.c —— pcapx 的 esp_console 宿主子命令
 *
 * 规格：docs/spec/pcapx.md（S2：RAM sink + esp_console 导出子命令）
 *
 * 提供两个命令（`help` 可见）：
 *   pcapx_ram_dump —— 把最近构造的 RAM sink 内容按 64 字节/行十六进制
 *                     打到 stdout（落在 run.log 里，宿主用
 *                     tools/pcapx_ram_extract.py 重组 pcap）。
 *                     必须在 attach 期间调用：core 在 detach 时会
 *                     close+free sink，detach 后缓冲已释放。
 *   pcapx_stats    —— 打印 pcapx_get_stats() 全部七项计数（单行 key=value）
 *
 * 用法（lab 工程示例）：
 *   esp_console_init(&(esp_console_config_t)ESP_CONSOLE_CONFIG_DEFAULT());
 *   pcapx_console_register();
 *   ... 之后 REPL 里 `pcapx_ram_dump` / `pcapx_stats`，
 *   或代码里 esp_console_run("pcapx_ram_dump", NULL)。
 * 必须在 esp_console_init() 之后调用（v6 的命令注册依赖 console 组件
 * 已初始化的堆配置，components/console/esp_console.h:152）。
 *
 * 依赖（lab 工程 CMake 需 PRV_REQUIRES）：console、pcapx。
 * 与 pcapx_sink_ram.c 的本地契约：extern 两个导出函数（current/dump），
 * 不经公共头文件——pcapx.h 是冻结接口，不添加 console 专用入口。
 */
#include <stdio.h>

#include "esp_console.h"
#include "esp_err.h"
#include "pcapx.h"

/* pcapx_sink_ram.c 导出（见该文件「导出给 pcapx_console.c」段） */
extern pcapx_sink_t *pcapx_sink_ram_current(void);
extern void pcapx_sink_ram_dump(pcapx_sink_t *sink);

static int cmd_ram_dump(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    pcapx_sink_t *sink = pcapx_sink_ram_current();
    if (sink == NULL) {
        printf("pcapx_ram_dump error no_sink (先 pcapx_sink_ram_new() 创建)\n");
        return 1;
    }
    pcapx_sink_ram_dump(sink);
    return 0;
}

static int cmd_stats(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    pcapx_stats_t st;
    pcapx_get_stats(&st);
    /* 与 pcapx.h pcapx_stats_t 字段一一对应；ring_high_wm 是第七项（字节数） */
    printf("pcapx_stats rx=%u tx=%u filtered=%u dropped=%u truncated=%u written=%u "
           "ring_high_wm=%u\n",
           (unsigned)st.rx, (unsigned)st.tx, (unsigned)st.filtered, (unsigned)st.dropped,
           (unsigned)st.truncated, (unsigned)st.written, (unsigned)st.ring_high_wm);
    return 0;
}

static const esp_console_cmd_t s_cmd_ram_dump = {
    .command = "pcapx_ram_dump",
    .help = "Dump RAM sink capture (hex, 64 bytes/line) for host-side reassembly",
    .hint = NULL,
    .func = cmd_ram_dump,
};

static const esp_console_cmd_t s_cmd_stats = {
    .command = "pcapx_stats",
    .help = "Print pcapx counters (rx tx filtered dropped truncated written ring_high_wm)",
    .hint = NULL,
    .func = cmd_stats,
};

esp_err_t pcapx_console_register(void)
{
    esp_err_t err = esp_console_cmd_register(&s_cmd_ram_dump);
    if (err != ESP_OK) {
        return err;
    }
    return esp_console_cmd_register(&s_cmd_stats);
}
