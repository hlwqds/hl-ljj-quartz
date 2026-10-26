/*
 * onvif_stats.c — ONVIF 组件内存统计实现。
 *
 * 无锁说明：登记/记账全部发生在组件各模块 init（单线程串行）与各自任务内，
 * 互不相干的标签各写各的槽位；dump 只在 console 任务跑。评估用途允许读数
 * 有竞争性抖动，不上互斥锁——避免统计本身成为内存/时序负担。
 */
#include "onvif_stats.h"

#include <string.h>

#include "esp_heap_caps.h"
#include "esp_log.h"

static const char *TAG = "onvif_stats";

typedef struct {
    const char *tag;
    const char *name;
    size_t bytes;
} static_ent_t;

typedef struct {
    const char *tag;
    onvif_stats_ledger_t led;
} mod_ent_t;

typedef struct {
    const char *name;
    TaskHandle_t handle;
} task_ent_t;

static mod_ent_t s_mods[ONVIF_STATS_MAX_MODULES];
static int s_mod_n;
static static_ent_t s_statics[ONVIF_STATS_MAX_STATICS];
static int s_static_n;
static task_ent_t s_tasks[ONVIF_STATS_MAX_MODULES];
static int s_task_n;

static mod_ent_t *find_mod(const char *tag)
{
    for (int i = 0; i < s_mod_n; i++) {
        if (strcmp(s_mods[i].tag, tag) == 0) {
            return &s_mods[i];
        }
    }
    if (s_mod_n >= ONVIF_STATS_MAX_MODULES) {
        return NULL;
    }
    s_mods[s_mod_n].tag = tag;
    return &s_mods[s_mod_n++];
}

void *onvif_stats_alloc(const char *tag, size_t size, uint32_t caps)
{
    void *p = heap_caps_malloc(size, caps);
    if (p == NULL) {
        return NULL;
    }
    mod_ent_t *m = find_mod(tag);
    if (m) {
        m->led.total_allocs++;
        m->led.total_bytes += size;
        m->led.live_allocs++;
        m->led.live_bytes += size;
        if (m->led.live_bytes > m->led.peak_bytes) {
            m->led.peak_bytes = m->led.live_bytes;
        }
    }
    return p;
}

void onvif_stats_free(const char *tag, void *p)
{
    if (p == NULL) {
        return;
    }
    mod_ent_t *m = find_mod(tag);
    if (m && m->led.live_allocs > 0) {
        m->led.live_allocs--;
        /* live_bytes 不回减：heap_caps 无法反查块大小，live 只减计数不减字节，
         * 语义为「该标签历史动过的量」，评估时以 total/peak 为准 */
    }
    free(p);
}

void onvif_stats_register_static(const char *tag, const char *name, size_t bytes)
{
    for (int i = 0; i < s_static_n; i++) {
        if (strcmp(s_statics[i].tag, tag) == 0 && strcmp(s_statics[i].name, name) == 0) {
            s_statics[i].bytes = bytes;
            return;
        }
    }
    if (s_static_n >= ONVIF_STATS_MAX_STATICS) {
        return;
    }
    s_statics[s_static_n] = (static_ent_t){.tag = tag, .name = name, .bytes = bytes};
    s_static_n++;
    find_mod(tag); /* 确保模块槽位存在，dump 时静态-only 模块也有行 */
}

void onvif_stats_register_task(const char *name, TaskHandle_t handle)
{
    if (s_task_n >= ONVIF_STATS_MAX_MODULES) {
        return;
    }
    s_tasks[s_task_n] = (task_ent_t){.name = name, .handle = handle};
    s_task_n++;
}

void onvif_stats_heap(const char *at)
{
    ESP_LOGI(TAG,
             "$$$ ONVIF HEAP@%s free_dma=%u free_internal=%u free_spiram=%u min_free=%u", at,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
             (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL));
}

void onvif_stats_dump(void)
{
    /* 每模块一行：静态缓冲合计 + 动态账本 + 栈水位（按 tag 名登记的任务） */
    uint32_t all_static = 0;
    for (int i = 0; i < s_mod_n; i++) {
        const char *tag = s_mods[i].tag;
        uint32_t st = 0;
        for (int j = 0; j < s_static_n; j++) {
            if (strcmp(s_statics[j].tag, tag) == 0) {
                st += s_statics[j].bytes;
            }
        }
        all_static += st;
        uint32_t hwm = 0;
        for (int j = 0; j < s_task_n; j++) {
            if (strcmp(s_tasks[j].name, tag) == 0 && s_tasks[j].handle != NULL) {
                hwm = uxTaskGetStackHighWaterMark(s_tasks[j].handle);
            }
        }
        char tail[40] = "";
        if (hwm) {
            /* RISC-V 端口 StackType_t 为 uint8_t，水位单位=字节 */
            snprintf(tail, sizeof(tail), " stack_hwm=%u bytes", (unsigned)hwm);
        }
        ESP_LOGI(TAG, "$$$ ONVIF STATS tag=%s static=%u heap_live=%u heap_peak=%u allocs=%u%s",
                 tag, (unsigned)st, (unsigned)s_mods[i].led.live_bytes,
                 (unsigned)s_mods[i].led.peak_bytes, (unsigned)s_mods[i].led.total_allocs, tail);
        for (int j = 0; j < s_static_n; j++) {
            if (strcmp(s_statics[j].tag, tag) == 0) {
                ESP_LOGI(TAG, "$$$ ONVIF STATS buf tag=%s name=%s bytes=%u", tag,
                         s_statics[j].name, (unsigned)s_statics[j].bytes);
            }
        }
    }
    uint32_t free_dma = heap_caps_get_free_size(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    uint32_t free_spiram = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    uint32_t min_free = heap_caps_get_minimum_free_size(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    ESP_LOGI(TAG,
             "$$$ ONVIF STATS tag=all static_total=%u free_dma=%u free_spiram=%u min_free=%u",
             (unsigned)all_static, (unsigned)free_dma, (unsigned)free_spiram,
             (unsigned)min_free);
}
