/* 宿主单元测试桩：让组件源文件在 gcc 下编译（不链接 IDF）。
#include <stdio.h>
 * md5/nonce 由测试注入（onvif_digest_bind），这里只需提供符号定义满足链接。 */
#pragma once

#include <stdint.h>
#include <stddef.h>

/* esp_log 桩：宏化成 printf，保留标记行可见性 */
#define ESP_LOGI(tag, fmt, ...) printf("[%s] " fmt "\n", tag, ##__VA_ARGS__)
#define ESP_LOGW(tag, fmt, ...) printf("[%s][W] " fmt "\n", tag, ##__VA_ARGS__)
#define ESP_LOGE(tag, fmt, ...) printf("[%s][E] " fmt "\n", tag, ##__VA_ARGS__)

/* esp_random 桩：默认 nonce 生成会调它（测试注入 nonce 后不可达，仍给定义） */
void esp_fill_random(void *buf, size_t len);
