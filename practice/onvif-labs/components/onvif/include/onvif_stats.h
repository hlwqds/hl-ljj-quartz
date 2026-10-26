/*
 * onvif_stats.h — ONVIF 组件内存统计（生产化重构新增，ch17 §17.5.2）。
 *
 * 三本账的第四本：模块内存账。用途是内存占用评估——谁占了多少、峰值多少、
 * 静态缓冲占多少、任务栈余量多少，一条 `$$$ ONVIF STATS` 标记行系列说清。
 *
 * 记账面分三层：
 *   1. 静态缓冲登记（register_static）：组件内 s_rx/s_frame 这类编译期定长的
 *      大缓冲，是内存占用的绝对大头，必须入账（不算进堆，但占 RAM）。
 *   2. 动态分配账本（alloc/free）：带模块标签的 heap_caps 包装；现有模块零动态
 *      分配（全部静态化是既定纪律），包装器约束后续增量不许开无名口子。
 *   3. 任务栈水位（register_task）：uxTaskGetStackHighWaterMark，评估栈配额。
 *
 * 堆面（free_dma/free_internal/free_spiram/min_free）由 heap_snapshot 落；
 * 原 rtsp_server 的 heap3() 并入此处，全组件单一来源。
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#ifdef __cplusplus
extern "C" {
#endif

#define ONVIF_STATS_MAX_MODULES 8
#define ONVIF_STATS_MAX_STATICS 12

/* 单模块内存账（动态部分） */
typedef struct {
    uint32_t live_allocs;
    uint32_t live_bytes;
    uint32_t peak_bytes;
    uint32_t total_allocs;
    uint32_t total_bytes;
} onvif_stats_ledger_t;

/* 带标签的动态分配（caps 透传 heap_caps_malloc，如 MALLOC_CAP_SPIRAM） */
void *onvif_stats_alloc(const char *tag, size_t size, uint32_t caps);
void onvif_stats_free(const char *tag, void *p);

/* 静态缓冲登记：init 时调用，bytes 为 sizeof(buf)。重复登记同名只更新。 */
void onvif_stats_register_static(const char *tag, const char *name, size_t bytes);

/* 任务栈水位登记：dump 时取 uxTaskGetStackHighWaterMark。 */
void onvif_stats_register_task(const char *name, TaskHandle_t handle);

/* 堆面快照标记行：$$$ ONVIF HEAP@<at> free_dma=… free_internal=… free_spiram=… min_free=…
 * （原 heap3() 的统一化；at 为业务位点，如 PLAYING/TEARDOWN） */
void onvif_stats_heap(const char *at);

/* 全量内存账标记行：每模块一行 $$$ ONVIF STATS tag=… static=… heap=… peak=… stack_hwm=…，
 * 末尾 tag=all 汇总行。console `mem` 命令与测试集 T25 消费。 */
void onvif_stats_dump(void);

#ifdef __cplusplus
}
#endif
