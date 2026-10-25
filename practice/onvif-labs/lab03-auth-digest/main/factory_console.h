#pragma once

/*
 * 串口控制台（自 factory_demo main.c 平移，裁掉 UI 分支的 stream 命令）。
 * esp_console REPL 跑在与日志同一 UART（115200），命令：status/ip/heap/restart。
 */
void factory_console_init(void);
