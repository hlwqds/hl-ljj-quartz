/*
 * pcapx_sink_ram.c —— RAM 环形缓冲 sink（pcap 字节流暂存，console 导出）
 *
 * 规格：docs/spec/pcapx.md；冻结接口：include/pcapx.h
 *   契约：core 在 open 成功后第一个 write 调用写入 24 字节 pcap 全局头
 *   （pcapx.h：write 注释「core 已先写全局头」），之后是若干
 *   「16 字节记录头 + incl_len 字节载荷」顺序拼接的 pcap 字节流。
 *
 * 数据结构与覆盖策略：
 *  - 全局头不进环，单独保存在 sink 内（24B stash）：环一旦覆盖过旧数据，
 *    最老的那份全局头必然先被吃掉，dump 就无法重组出合法 pcap——所以
 *    它必须永不淘汰。dump 输出 = 全局头 + 环窗口，两者拼起来恒为合法 pcap。
 *  - 环以「整条记录」为覆盖单位（不是裸字节）：满时从最旧一端弹出完整
 *    记录（16B 头 + 其 incl_len 载荷）直到放得下新记录。裸字节覆盖会把
 *    窗口起点切在记录中间，宿主只能靠启发式重新同步；记录粒度淘汰让
 *    pcapx_ram_extract.py 可以零猜测精确重组。
 *  - 为知道记录边界，sink 边写边解析 pcap 流（24B 全局头 → 16B 记录头 →
 *    incl_len 载荷 → …）。记录头校验失败（长度字段不合理）时滑窗 1 字节
 *    重同步并计数，保证流内嵌错位后能恢复。
 *
 * 统计口径（本文件实现，console/extractor 输出与之对齐）：
 *  - records_parsed：通过记录头校验的记录总数（= 现存环内 + 已被覆盖 +
 *    oversize 丢弃三者之和）
 *  - records_stored：实际放入过环的记录数；环内现存 = stored - evicted
 *  - records_evicted / bytes_evicted：因环满被覆盖的「最旧」记录数 / 字节数
 *  - dropped_oversize：单条记录(16+incl_len) 大于环容量，整条丢弃（不进环）
 *  - resyncs：记录头校验失败、滑动重同步的次数（0 为正常）
 *  注意「环满丢新」的 core 契约统计（pcapx_stats_t.dropped）计的是 core
 *  SPSC 环满丢新；本 sink 的 evicted 是 RAM sink 自己的第二层满（覆盖
 *  最旧），二者口径不同、不重叠：core 环丢的帧根本到不了这里。
 *
 * 生命周期：open() 清空重置（支持同一 sink 对象重复 attach）；
 * close() 不清缓冲。注意 core 在 detach 时 close 后立即 free_fn（所有权
 * 移交契约）——所以「detach 之后」缓冲已随 sink 释放，导出必须在
 * **attach 期间**进行（console 流程：attach → 打流 → pcapx_ram_dump →
 * detach）。dump 与 writer 并发由互斥量串行化，见下。
 *
 * 并发：write() 只在 writer 任务调用（契约），dump 在 console 任务——
 * 构造器创建静态分配的 FreeRTOS 互斥量保护环指针域；快照在锁内完成
 * memcpy（writer 阻塞几十 µs 量级，契约允许 sink 操作阻塞，tap 路径不受
 * 影响——core 的 SPSC 环是另一层）。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_err.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#include "pcapx.h"

#define TAG "pcapx"

/* pcap 常量（与 S1 core 写出的格式一致，µs 魔数 + LINKTYPE_ETHERNET=1） */
#define PCAP_GHDR_LEN 24
#define PCAP_RHDR_LEN 16
#define PCAP_MAGIC_LE 0xd4c3b2a1 /* 小端读出的 0xa1b2c3d4 */

/* 记录头长度字段合理性上限（snaplen 不会超过它；防流错位后把垃圾当长度） */
#define RAM_LEN_SANITY (256 * 1024)

/* 记录头里 incl_len/orig_len 的字节偏移 */
#define RHDR_OFF_INCL 8
#define RHDR_OFF_ORIG 12

/* 导出快照（供 dump 与外部工具）：写在前面避免使用点先于定义 */
size_t pcapx_sink_ram_snapshot(pcapx_sink_t *sink, uint8_t *dst, size_t dst_cap);

/* 本文件导出给 pcapx_console.c 的观测接口（无公共头，两文件本地契约；
 * 不进冻结的 include/pcapx.h） */
typedef struct {
    size_t cap;              /* 环容量（字节） */
    size_t used;             /* 环内现存字节数 */
    uint32_t records_parsed; /* 口径见文件头 */
    uint32_t records_stored;
    uint32_t records_evicted;
    uint32_t bytes_evicted;
    uint32_t dropped_oversize;
    uint32_t resyncs;
} pcapx_ram_info_t;

typedef struct {
    pcapx_sink_t base; /* 必须是首成员 */
    uint8_t *buf;
    size_t cap;
    size_t head; /* 最老字节偏移 */
    size_t used; /* 现存字节数 */
    SemaphoreHandle_t lock;
    StaticSemaphore_t lock_mem;

    /* pcap 流解析状态（仅 writer 任务访问） */
    enum { ST_GLOBAL = 0, ST_RHDR, ST_PAY, ST_PAY_SKIP } st;
    uint8_t ghdr[PCAP_GHDR_LEN];
    size_t gfill;
    uint8_t rhdr[PCAP_RHDR_LEN];
    size_t rfill;
    size_t pay_rem;

    /* 统计 */
    uint32_t records_parsed, records_stored, records_evicted, bytes_evicted;
    uint32_t dropped_oversize, resyncs;
} ram_sink_t;

/* 最近一次构造的 RAM sink（console 导出入口用；单实例场景，见构造器） */
static ram_sink_t *s_current;

static inline uint32_t rd_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* ---- 环基础操作（调用者持锁） ---- */

static void ring_put(ram_sink_t *me, const uint8_t *src, size_t n)
{
    size_t tail = (me->head + me->used) % me->cap;
    size_t first = me->cap - tail;
    if (first > n) {
        first = n;
    }
    memcpy(me->buf + tail, src, first);
    memcpy(me->buf, src + first, n - first);
    me->used += n;
}

static void ring_get(ram_sink_t *me, size_t offset, uint8_t *dst, size_t n)
{
    size_t pos = (me->head + offset) % me->cap;
    size_t first = me->cap - pos;
    if (first > n) {
        first = n;
    }
    memcpy(dst, me->buf + pos, first);
    memcpy(dst + first, me->buf, n - first);
}

/* 从最旧一端弹出一条完整记录（16B 头 + incl_len 载荷） */
static void evict_one(ram_sink_t *me)
{
    uint8_t hdr[PCAP_RHDR_LEN];
    ring_get(me, 0, hdr, sizeof(hdr));
    size_t rec = PCAP_RHDR_LEN + (size_t)rd_le32(hdr + RHDR_OFF_INCL);
    if (rec > me->used) { /* 防御：写入侧保证整记录，正常不可达 */
        rec = me->used;
    }
    me->head = (me->head + rec) % me->cap;
    me->used -= rec;
    me->records_evicted++;
    me->bytes_evicted += (uint32_t)rec;
}

/* 保证环内可再容纳 rec 字节（淘汰最旧若干条整记录） */
static void make_room(ram_sink_t *me, size_t rec)
{
    while (me->used + rec > me->cap) {
        evict_one(me);
    }
}

/* 记录头长度字段校验。incl_len 上界用全局头里的 snaplen（pcap 语义：
 * 捕获长度恒 ≤ snaplen，validate.py 断言同一条）；orig_len 是真实线上
 * 长度（含巨型帧），用宽松定值上界。收紧 incl 是重同步抗假头的关键：
 * 垃圾字节滑出的窗口必须同时骗过「incl ≤ snaplen 且 orig ≥ incl 且
 * orig ≤ 262144」才算假阳性。 */
static bool rhdr_valid(const ram_sink_t *me, const uint8_t *h)
{
    uint32_t incl = rd_le32(h + RHDR_OFF_INCL);
    uint32_t orig = rd_le32(h + RHDR_OFF_ORIG);
    uint32_t snap = rd_le32(me->ghdr + 16); /* pcap 全局头 snaplen 字段 */
    uint32_t incl_max = (snap > 0 && snap < RAM_LEN_SANITY) ? snap : RAM_LEN_SANITY;
    /* 合法 pcap 记录：截断时 incl < orig，不截断时相等；orig < incl 必为错位 */
    return incl <= incl_max && orig <= RAM_LEN_SANITY && orig >= incl;
}

/* 载荷阶段结束后的公共跳转（含 incl_len==0 的空载荷记录） */
static void pay_done(ram_sink_t *me)
{
    me->st = ST_RHDR;
    me->rfill = 0;
}

/* ---- vtable ---- */

static esp_err_t ram_open(pcapx_sink_t *s)
{
    ram_sink_t *me = (ram_sink_t *)s;
    xSemaphoreTake(me->lock, portMAX_DELAY);
    me->head = 0;
    me->used = 0;
    me->st = ST_GLOBAL;
    me->gfill = 0;
    me->rfill = 0;
    me->pay_rem = 0;
    me->records_parsed = 0;
    me->records_stored = 0;
    me->records_evicted = 0;
    me->bytes_evicted = 0;
    me->dropped_oversize = 0;
    me->resyncs = 0;
    xSemaphoreGive(me->lock);
    ESP_LOGI(TAG, "SINK_OPEN sink=ram cap=%u", (unsigned)me->cap);
    return ESP_OK;
}

static esp_err_t ram_write(pcapx_sink_t *s, const void *buf, size_t len)
{
    ram_sink_t *me = (ram_sink_t *)s;
    const uint8_t *p = buf;
    size_t n = len;

    while (n > 0) {
        size_t take;
        switch (me->st) {
        case ST_GLOBAL:
            take = n < (PCAP_GHDR_LEN - me->gfill) ? n : (PCAP_GHDR_LEN - me->gfill);
            memcpy(me->ghdr + me->gfill, p, take);
            me->gfill += take;
            if (me->gfill == PCAP_GHDR_LEN) {
                if (rd_le32(me->ghdr) != PCAP_MAGIC_LE) {
                    /* 契约要求 core 第一个 write 是全局头；魔数不符=流错位，
                     * 照存（dump 输出仍含这 24B），但留下观测点 */
                    ESP_LOGW(TAG, "ram: global header magic mismatch (%08x)", rd_le32(me->ghdr));
                }
                me->st = ST_RHDR;
                me->rfill = 0;
            }
            break;

        case ST_RHDR:
            take = n < (PCAP_RHDR_LEN - me->rfill) ? n : (PCAP_RHDR_LEN - me->rfill);
            memcpy(me->rhdr + me->rfill, p, take);
            me->rfill += take;
            if (me->rfill == PCAP_RHDR_LEN) {
                if (!rhdr_valid(me, me->rhdr)) {
                    /* 滑窗重同步：丢掉滑窗最老 1 字节，腾位再收 1 字节。
                     * 本轮 take 字节已入滑窗，正常推进 p/n 即可 */
                    me->resyncs++;
                    memmove(me->rhdr, me->rhdr + 1, PCAP_RHDR_LEN - 1);
                    me->rfill = PCAP_RHDR_LEN - 1;
                    break;
                }
                uint32_t incl = rd_le32(me->rhdr + RHDR_OFF_INCL);
                me->records_parsed++;
                if ((size_t)incl + PCAP_RHDR_LEN > me->cap) {
                    /* 单记录大于整环：整条丢弃，跳过其载荷 */
                    me->dropped_oversize++;
                    ESP_LOGW(TAG, "ram: record too big incl=%u cap=%u, dropped",
                             (unsigned)incl, (unsigned)me->cap);
                    me->pay_rem = incl;
                    me->st = ST_PAY_SKIP;
                    if (me->pay_rem == 0) {
                        pay_done(me);
                    }
                    break;
                }
                xSemaphoreTake(me->lock, portMAX_DELAY);
                make_room(me, PCAP_RHDR_LEN + (size_t)incl);
                ring_put(me, me->rhdr, PCAP_RHDR_LEN);
                xSemaphoreGive(me->lock);
                me->records_stored++;
                me->pay_rem = incl;
                me->st = ST_PAY;
                if (me->pay_rem == 0) {
                    pay_done(me);
                }
            }
            break;

        case ST_PAY:
            take = n < me->pay_rem ? n : me->pay_rem;
            xSemaphoreTake(me->lock, portMAX_DELAY);
            ring_put(me, p, take); /* 容量在记录头阶段已足额预留 */
            xSemaphoreGive(me->lock);
            me->pay_rem -= take;
            if (me->pay_rem == 0) {
                pay_done(me);
            }
            break;

        case ST_PAY_SKIP:
            take = n < me->pay_rem ? n : me->pay_rem;
            me->pay_rem -= take;
            if (me->pay_rem == 0) {
                pay_done(me);
            }
            break;

        default:
            take = 0;
            break;
        }

        p += take;
        n -= take;
        if (take == 0 && n > 0) {
            /* 防御：所有状态对 n>0 都应至少消费 1 字节；到不了这里，
             * 万一到了强推 1 字节避免死循环 */
            me->resyncs++;
            p++;
            n--;
        }
    }
    return ESP_OK;
}

static esp_err_t ram_close(pcapx_sink_t *s)
{
    ram_sink_t *me = (ram_sink_t *)s;
    /* 不清缓冲（free_fn 前的窗口期内仍可 dump）；导出须在 attach 期间做，
     * 见文件头生命周期说明 */
    ESP_LOGI(TAG,
             "SINK_CLOSE sink=ram parsed=%u stored=%u evicted=%u oversize=%u resync=%u",
             (unsigned)me->records_parsed, (unsigned)me->records_stored,
             (unsigned)me->records_evicted, (unsigned)me->dropped_oversize,
             (unsigned)me->resyncs);
    return ESP_OK;
}

static void ram_free(pcapx_sink_t *s)
{
    ram_sink_t *me = (ram_sink_t *)s;
    if (s_current == me) {
        s_current = NULL;
    }
    vSemaphoreDelete(me->lock);
    free(me->buf);
    free(me);
}

/* ---- 导出给 pcapx_console.c 的观测接口 ---- */

pcapx_sink_t *pcapx_sink_ram_current(void)
{
    return s_current != NULL ? &s_current->base : NULL;
}

void pcapx_sink_ram_info(pcapx_sink_t *sink, pcapx_ram_info_t *out)
{
    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof(*out));
    if (sink == NULL || sink->open != ram_open) {
        return;
    }
    ram_sink_t *me = (ram_sink_t *)sink;
    xSemaphoreTake(me->lock, portMAX_DELAY);
    out->cap = me->cap;
    out->used = me->used;
    out->records_parsed = me->records_parsed;
    out->records_stored = me->records_stored;
    out->records_evicted = me->records_evicted;
    out->bytes_evicted = me->bytes_evicted;
    out->dropped_oversize = me->dropped_oversize;
    out->resyncs = me->resyncs;
    xSemaphoreGive(me->lock);
}

/* console 导出：把「全局头 + 环窗口」按 64 字节/行十六进制打到 stdout，
 * 供宿主 tools/pcapx_ram_extract.py 从 run.log 提取（行格式两边对齐）：
 *   pcapx_ram_dump begin cap=N used=N parsed=N stored=N evicted=N oversize=N resync=N
 *   pcapx_ram_dump 00000000 d4 c3 b2 a1 ...（每行 64 字节，行首 8 位十六进制偏移）
 *   pcapx_ram_dump end bytes=N */
void pcapx_sink_ram_dump(pcapx_sink_t *sink)
{
    pcapx_ram_info_t info;
    pcapx_sink_ram_info(sink, &info);
    if (sink == NULL || info.cap == 0) {
        printf("pcapx_ram_dump error no_sink\n");
        return;
    }
    printf("pcapx_ram_dump begin cap=%u used=%u parsed=%u stored=%u evicted=%u oversize=%u resync=%u\n",
           (unsigned)info.cap, (unsigned)info.used, (unsigned)info.records_parsed,
           (unsigned)info.records_stored, (unsigned)info.records_evicted,
           (unsigned)info.dropped_oversize, (unsigned)info.resyncs);

    uint8_t *snap = malloc(info.used + PCAP_GHDR_LEN);
    if (snap == NULL) {
        printf("pcapx_ram_dump error alloc_failed need=%u\n",
               (unsigned)(info.used + PCAP_GHDR_LEN));
        return;
    }
    size_t total = pcapx_sink_ram_snapshot(sink, snap, info.used + PCAP_GHDR_LEN);
    for (size_t off = 0; off < total; off += 64) {
        size_t n = total - off < 64 ? total - off : 64;
        printf("pcapx_ram_dump %08x", (unsigned)off);
        for (size_t i = 0; i < n; i++) {
            printf(" %02x", snap[off + i]);
        }
        printf("\n");
    }
    free(snap);
    printf("pcapx_ram_dump end bytes=%u\n", (unsigned)total);
}

/* 把「全局头 + 环窗口（最旧→最新）」快照进 dst；返回实际复制字节数。
 * dst 容量不足时截断（调用方应按 info().used + 24 精确分配）。
 * 全程持锁拷贝：head 在淘汰时会变，锁外读会把窗口起点读串。 */
size_t pcapx_sink_ram_snapshot(pcapx_sink_t *sink, uint8_t *dst, size_t dst_cap)
{
    if (sink == NULL || sink->open != ram_open || dst == NULL) {
        return 0;
    }
    ram_sink_t *me = (ram_sink_t *)sink;
    size_t gfill = me->gfill < PCAP_GHDR_LEN ? me->gfill : PCAP_GHDR_LEN;

    xSemaphoreTake(me->lock, portMAX_DELAY);
    size_t gcopy = gfill < dst_cap ? gfill : dst_cap;
    memcpy(dst, me->ghdr, gcopy);
    size_t wcopy = me->used;
    if (wcopy > dst_cap - gcopy) {
        wcopy = dst_cap - gcopy;
    }
    ring_get(me, 0, dst + gcopy, wcopy);
    xSemaphoreGive(me->lock);
    return gcopy + wcopy;
}

/* ---- 构造器 ---- */

pcapx_sink_t *pcapx_sink_ram_new(size_t cap_bytes)
{
    if (cap_bytes < PCAP_GHDR_LEN + PCAP_RHDR_LEN) {
        /* 至少要放得下一条空载荷记录，否则任何记录都进不了环 */
        cap_bytes = PCAP_GHDR_LEN + PCAP_RHDR_LEN;
    }
    ram_sink_t *me = calloc(1, sizeof(*me));
    if (me == NULL) {
        return NULL;
    }
    /* 捕获缓冲走内部 RAM（真机开了 PSRAM 时 malloc 可能给 SPIRAM，
     * 抓包路径要确定性内存延迟）；内部 RAM 不足退回默认堆 */
    me->buf = heap_caps_calloc(1, cap_bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (me->buf == NULL) {
        me->buf = calloc(1, cap_bytes);
        if (me->buf == NULL) {
            free(me);
            return NULL;
        }
    }
    me->cap = cap_bytes;
    me->lock = xSemaphoreCreateMutexStatic(&me->lock_mem);
    me->st = ST_GLOBAL;

    /* ATTACH 行 sink=<name> 的取值（pcapx.h）。静态缓冲：RAM sink 实际
     * 单实例使用（s_current 只留最新），多实例时后者覆盖前者的显示名 */
    static char name[32];
    snprintf(name, sizeof(name), "ram:%uB", (unsigned)cap_bytes);
    me->base.name = name;
    me->base.open = ram_open;
    me->base.write = ram_write;
    me->base.close = ram_close;
    me->base.free_fn = ram_free;

    s_current = me;
    return &me->base;
}
