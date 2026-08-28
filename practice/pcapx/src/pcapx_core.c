/*
 * pcapx —— 核心实现（S1 切片：换装接入 + tap 拷贝路径 + SPSC 环 + writer 任务）
 *
 * 规格：docs/spec/pcapx.md（行为契约第 4 节逐条对应）
 * 接口：include/pcapx.h（冻结契约）
 *
 * 结构总览：
 *
 *   eth RX 任务 ──netif->input(wrap)──┐          ┌──> 原tcpip_input
 *                                    ├─ tap_capture ─┤
 *   tcpip_thread ─linkoutput(wrap)───┘   (µs时间戳  │ SPSC 环
 *                                        +硬过滤+    ▼
 *                                        线性化入环) pcapx_task(writer, 优先级可配)
 *                                             │ 出环 → pcap 记录头 + sink->write
 *                                             ▼
 *                                        pcapx_sink_t (semihost / ram / uart, S2 提供)
 *
 * 线程与锁模型（本文件最重要的设计事实）：
 *  - 生产者实际有两类上下文：input wrap 跑在 eth RX 任务（openeth 路径：
 *    esp_eth rx task → esp_netif_receive → ethernetif_input → netif->input，
 *    esp_netif/lwip/netif/ethernetif.c:139），linkoutput wrap 跑在 tcpip_thread。
 *    规格里「SPSC 环」的名字因此按「单一消费者」理解；多生产者由同一把
 *    portENTER_CRITICAL 旋锁把整个入环操作（元数据+帧数据 memcpy）串行化，
 *    换取丢新计数与环指针的无竞态（memcpy 上界 = snaplen，临界区有界）。
 *  - 消费者只有一个（pcapx_task），出环大拷贝放在临界区外是安全的：
 *    生产者只写 [head, head+need)，永不触碰未消费区 [tail, head)。
 *  - 溢出策略：丢新不丢旧（保序 + 计数语义简单），dropped 聚合每 32 次打一条 W。
 */

#include <stdint.h>
#include <string.h>

#include "esp_err.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/prot/ethernet.h" /* ETHTYPE_IP/ETHTYPE_IPV6（经 prot/ieee.h） */

#include "pcapx.h"

static const char *TAG = "pcapx";

/* ---------------- 常量 ---------------- */

#define PCAPX_RING_PREFIX 12         /* 环内每帧前缀：8B ts_us + 2B orig_len + 2B caplen */
#define PCAPX_DROP_LOG_EVERY 32      /* 契约：drop 聚合 N=32 次打一条，防刷屏 */
#define PCAPX_PCAP_GHDR_LEN 24       /* pcap 全局头字节数 */
#define PCAPX_PCAP_RHDR_LEN 16       /* pcap 记录头字节数 */
#define PCAPX_PCAP_MAGIC 0xa1b2c3d4U /* µs 分辨率、小端文件的魔数值 */
#define PCAPX_PCAP_LINKTYPE_ETH 1    /* LINKTYPE_ETHERNET */
/* 过滤器需要窥视的最长前缀：以太网头 14 + IPv4 最差 IHL(15*4=60) + 4B 端口 */
#define PCAPX_FILTER_SCAN_MAX 78

#define PCAPX_MIN(a, b) ((a) < (b) ? (a) : (b))


/* ---------------- 模块状态 ---------------- */

/* attach 快照（attach 成功后只读；detach 完成前有效） */
static struct netif *s_netif;
static netif_input_fn s_orig_input;
static netif_linkoutput_fn s_orig_linkoutput;
static uint8_t s_direction;
static uint32_t s_snaplen;
static pcapx_filter_t s_filter;
static pcapx_sink_t *s_sink;

/* 运行时 */
static volatile bool s_enabled;         /* tap 门控（wrap 常驻，flag 关 = 纯直通近零开销） */
static volatile bool s_writer_run;      /* writer 生命周期 flag：detach 置 false 促其自删 */
static volatile uint32_t s_inflight;    /* 已越过 s_enabled 检查、仍在 tap 里的帧数（detach 栅栏） */
static volatile TaskHandle_t s_writer_handle; /* tap 侧空转唤醒用；writer 自删前置 NULL */
static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static uint8_t *s_ring;    /* 环存储（internal RAM，确定性访问） */
static size_t s_ring_size; /* attach 后不变 */
static uint32_t s_head, s_tail; /* 单调递增字节计数；物理位置 = pos % s_ring_size（持 s_lock 访问） */
static uint8_t *s_bounce;       /* writer 出环线性化弹床（attach 分配，snaplen 字节） */
static pcapx_stats_t s_stats;   /* 全部字段在 s_lock 内更新 */
static SemaphoreHandle_t s_writer_done; /* writer 排空+close 后 give，detach 据此回收 */
static bool s_sink_err_logged;          /* sink 中途写失败只报一次，防串口风暴 */

/* ---------------- 小工具：显式小端序列化 ---------------- */

/* pcap 魔数 0xa1b2c3d4 按「文件字节序=小端」落盘即 d4 c3 b2 a1，与
 * espressif/pcap 参考实现默认路径（native fwrite 0xA1B2C3D4 于 LE 目标）等价；
 * 全部字段显式逐字节序列化，规避结构体填充/字节序假设 */
static void put_le16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v & 0xff);
    p[1] = (uint8_t)(v >> 8);
}

static void put_le32(uint8_t *p, uint32_t v)
{
    put_le16(p, (uint16_t)(v & 0xffff));
    put_le16(p + 2, (uint16_t)(v >> 16));
}

static void put_le64(uint8_t *p, uint64_t v)
{
    put_le32(p, (uint32_t)(v & 0xffffffffu));
    put_le32(p + 4, (uint32_t)(v >> 32));
}

static uint16_t get_le16(const uint8_t *p)
{
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint64_t get_le64(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) {
        v = (v << 8) | p[i];
    }
    return v;
}

static uint16_t get_be16(const uint8_t *p)
{
    return (uint16_t)((p[0] << 8) | p[1]);
}

/* ---------------- 环读写 ---------------- */

/* ring_write：生产者持 s_lock 时写 [head, head+need)；
 * ring_read：消费者读 [tail, head) 已提交区——该区在 tail 推进前不会被生产者覆写
 * （生产者只写 head 之后的空间），故大拷贝可放临界区外。 */
static void ring_write(uint32_t pos, const void *src, size_t len)
{
    size_t off = pos % s_ring_size;
    size_t first = s_ring_size - off;
    if (first > len) {
        first = len;
    }
    memcpy(&s_ring[off], src, first);
    if (first < len) {
        memcpy(s_ring, (const uint8_t *)src + first, len - first); /* 回卷段 */
    }
}

static void ring_read(uint32_t pos, void *dst, size_t len)
{
    size_t off = pos % s_ring_size;
    size_t first = s_ring_size - off;
    if (first > len) {
        first = len;
    }
    memcpy(dst, &s_ring[off], first);
    if (first < len) {
        memcpy((uint8_t *)dst + first, s_ring, len - first); /* 回卷段 */
    }
}

/* ---------------- 过滤器（pbuf 链安全：基于线性化前缀） ---------------- */

static bool filter_active(void)
{
    return s_filter.ethertype != 0 || s_filter.ip_proto != 0 || s_filter.port != 0;
}

/* h/n：帧的前 n 字节线性化视图（n 短于所需 → 判不匹配，计 filtered）。
 * IPv6 不跟随扩展头（non-goal）；VLAN 帧在设置 L4 过滤时判不匹配。 */
static bool filter_match(const uint8_t *h, uint16_t n)
{
    if (n < 14) {
        return false;
    }
    uint16_t eth = get_be16(&h[12]);
    if (s_filter.ethertype != 0 && eth != s_filter.ethertype) {
        return false;
    }

    if (s_filter.ip_proto != 0 || s_filter.port != 0) {
        uint8_t proto;
        uint16_t l4_off;
        if (eth == ETHTYPE_IP) {
            if (n < 24) {
                return false; /* 拿不到 IPv4 头的 proto 字节（偏移 14+9） */
            }
            proto = h[23];
            l4_off = (uint16_t)(14 + (h[14] & 0x0f) * 4);
        } else if (eth == ETHTYPE_IPV6) {
            if (n < 21) {
                return false; /* 拿不到 IPv6 next header（偏移 14+6） */
            }
            proto = h[20];
            l4_off = 14 + 40;
        } else {
            return false; /* 非 IP 帧无 L4 语义 */
        }
        if (s_filter.ip_proto != 0 && proto != s_filter.ip_proto) {
            return false;
        }
        if (s_filter.port != 0) {
            if (n < l4_off + 4) {
                return false;
            }
            /* 契约：filter->port 即网络序，与线上字节直接比较，命中 src 或 dst 任一 */
            uint16_t sport = get_be16(&h[l4_off]);
            uint16_t dport = get_be16(&h[l4_off + 2]);
            if (sport != s_filter.port && dport != s_filter.port) {
                return false;
            }
        }
    }
    return true;
}

/* ---------------- tap 路径（eth RX 任务 / tcpip_thread；禁 malloc/阻塞/printf） ---------------- */

static void tap_capture(uint8_t dir, struct pbuf *p)
{
    portENTER_CRITICAL(&s_lock);
    if (!s_enabled) {
        portEXIT_CRITICAL(&s_lock);
        return;
    }
    /* inflight 与 enable 检查在同一临界区：detach 侧先关 flag 再等 inflight==0，
     * 两者不会互相穿过（spinlock 提供所需的 SMP 内存序） */
    s_inflight++;
    /* rx/tx 计所有到达 wrap 的帧（过滤前）；方向未选中的帧也不截走计数 */
    if (dir == PCAPX_DIR_RX) {
        s_stats.rx++;
    } else {
        s_stats.tx++;
    }
    portEXIT_CRITICAL(&s_lock);

    if ((s_direction & dir) == 0) {
        goto out;
    }

    {
        int64_t ts_us = esp_timer_get_time();
        uint16_t tot_len = p->tot_len; /* u16，含以太网填充，即 pcap 的 orig_len */
        uint32_t caplen = PCAPX_MIN((uint32_t)tot_len, s_snaplen);
        /* 硬过滤：先取帧头前缀做结构化匹配（pbuf 链安全，不假设载荷连续） */
        if (filter_active()) {
            uint8_t hdr[PCAPX_FILTER_SCAN_MAX];
            uint16_t n = pbuf_copy_partial(p, hdr, PCAPX_MIN((uint16_t)PCAPX_FILTER_SCAN_MAX, tot_len), 0);
            if (!filter_match(hdr, n)) {
                portENTER_CRITICAL(&s_lock);
                s_stats.filtered++;
                portEXIT_CRITICAL(&s_lock);
                goto out;
            }
        }

        size_t need = PCAPX_RING_PREFIX + caplen;
        portENTER_CRITICAL(&s_lock);
        size_t used = s_head - s_tail;
        if (need > s_ring_size - used) {
            /* 环满 → 丢新不丢旧（保序、计数可审计） */
            s_stats.dropped++;
            uint32_t cnt = s_stats.dropped;
            portEXIT_CRITICAL(&s_lock);
            if (cnt % PCAPX_DROP_LOG_EVERY == 0) {
                /* 契约观测点。tap 上下文唯一被豁免的打印：32 次 drop 才一条，
                 * 且在临界区外打（先快照计数再放锁） */
                ESP_LOGW(TAG, "DROP cnt=%u", (unsigned)cnt);
            }
            goto out;
        }
        uint32_t pos = s_head;
        uint8_t prefix[PCAPX_RING_PREFIX];
        put_le64(prefix, (uint64_t)ts_us);
        put_le16(prefix + 8, tot_len);
        put_le16(prefix + 10, (uint16_t)caplen);
        ring_write(pos, prefix, sizeof(prefix));
        /* pbuf_copy_partial 带偏移分两段直写环内，避免弹床二次拷贝；
         * 此刻仍持锁（多生产者串行化，见文件头线程模型）。
         * S3 集成修复（2026-08-27）：帧数据必须落在 prefix 之后，此前实现
         * 漏加 PCAPX_RING_PREFIX 偏移，帧头 12B 盖掉元数据 → writer 解析出
         * 垃圾 caplen（≤65535）→ tail 越过 head → used 下溢 → 越界写环踩堆 */
        size_t off = (pos + PCAPX_RING_PREFIX) % s_ring_size;
        size_t first = PCAPX_MIN((size_t)caplen, s_ring_size - off);
        pbuf_copy_partial(p, &s_ring[off], (uint16_t)first, 0);
        if (first < caplen) {
            pbuf_copy_partial(p, s_ring, (uint16_t)(caplen - first), (uint16_t)first);
        }
        s_head = pos + (uint32_t)need;
        used += need;
        if (used > s_stats.ring_high_wm) {
            s_stats.ring_high_wm = (uint32_t)used;
        }
        if (caplen < tot_len) {
            s_stats.truncated++; /* 只对已入环的帧计截断 */
        }
        portEXIT_CRITICAL(&s_lock);
    }

    /* 空转唤醒 writer：先读句柄再 give。句柄在 writer 自删前置 NULL，而 writer
     * 只会在 detach 的 inflight 栏放行之后才退出，故此处句柄必有效（判空为防御） */
    {
        TaskHandle_t w = s_writer_handle;
        if (w) {
            xTaskNotifyGive(w);
        }
    }

out:
    portENTER_CRITICAL(&s_lock);
    s_inflight--;
    portEXIT_CRITICAL(&s_lock);
}

/* ---------------- 换装 wrap（常驻安装，s_enabled 门控） ---------------- */

/* capture 在调用原 input 之前（规格设计决定）：此刻 pbuf 仍归调用者所有，
 * 原始 input（tcpip_input）会把它投递进 tcpip 邮箱、所有权移交协议栈 */
static err_t pcapx_wrap_input(struct pbuf *p, struct netif *inp)
{
    tap_capture(PCAPX_DIR_RX, p);
    return s_orig_input(p, inp);
}

/* TX 同理：linkoutput 调用时帧已组装完整（ethernet_output 的最终步）；
 * 返回值透传，不改变网栈发送语义 */
static err_t pcapx_wrap_linkoutput(struct netif *netif, struct pbuf *p)
{
    tap_capture(PCAPX_DIR_TX, p);
    return s_orig_linkoutput(netif, p);
}

/* ---------------- writer 任务（专职出环写 sink，允许阻塞） ---------------- */

static esp_err_t sink_write_checked(const void *buf, size_t len)
{
    esp_err_t err = s_sink->write(s_sink, buf, len);
    if (err != ESP_OK && !s_sink_err_logged) {
        /* 非契约行：sink 中途写失败（如宿主磁盘满）只报一次；后续帧照常出环丢弃，
         * 防止环被塞死、把 tap 侧拖成持续 drop */
        s_sink_err_logged = true;
        ESP_LOGW(TAG, "SINK_WRITE err=0x%x sink=%s", (unsigned)err, s_sink->name);
    }
    return err;
}

static void writer_drain(void)
{
    uint8_t prefix[PCAPX_RING_PREFIX];
    for (;;) {
        portENTER_CRITICAL(&s_lock);
        if (s_head == s_tail) {
            portEXIT_CRITICAL(&s_lock);
            return;
        }
        uint32_t pos = s_tail;
        ring_read(pos, prefix, sizeof(prefix)); /* 12B 小拷贝留在临界区内 */
        portEXIT_CRITICAL(&s_lock);

        uint64_t ts_us = get_le64(prefix);
        uint16_t orig_len = get_le16(prefix + 8);
        uint16_t caplen = get_le16(prefix + 10);

        /* 帧数据大拷贝在临界区外：[tail, head) 在 tail 推进前对生产者只读 */
        ring_read(pos + PCAPX_RING_PREFIX, s_bounce, caplen);

        uint8_t rec[PCAPX_PCAP_RHDR_LEN];
        put_le32(&rec[0], (uint32_t)(ts_us / 1000000)); /* ts_sec */
        put_le32(&rec[4], (uint32_t)(ts_us % 1000000)); /* ts_usec（magic 为 µs 分辨率） */
        put_le32(&rec[8], caplen);                       /* incl_len < orig_len 即截断 */
        put_le32(&rec[12], orig_len);                    /* orig_len */
        sink_write_checked(rec, sizeof(rec));
        sink_write_checked(s_bounce, caplen);

        portENTER_CRITICAL(&s_lock);
        s_tail = pos + PCAPX_RING_PREFIX + caplen;
        s_stats.written++; /* 计出环并已交 sink 的帧（sink 失败时亦计，见报告） */
        portEXIT_CRITICAL(&s_lock);
    }
}

static void pcapx_task(void *arg)
{
    (void)arg;
    while (s_writer_run) {
        /* 清计数型 take：排空期间 tap 的 give 会累积，不会丢唤醒 */
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        writer_drain();
    }
    writer_drain();         /* detach 已停 tap：最后一轮排空余量（丢新策略下无新帧） */
    s_sink->close(s_sink);  /* close 统一由 writer 执行：保证所有记录写完再关 */

    xSemaphoreGive(s_writer_done);
    s_writer_handle = NULL; /* 先发布空句柄再自删：此后 tap/控制面不再引用本任务 */

    /* 自删语义（FreeRTOS 系列 ch5/ch9）：vTaskDelete(NULL) 只把 TCB 挂到待回收
     * 链表，栈与 TCB 由 Idle 任务收尸；本行之后不得再触碰任何共享状态。
     * 竞态安全性：detach 拿到 s_writer_done 即知 writer 已停用环/sink；即使
     * detach 提前返回、新 attach 抢先重写 s_writer_handle，本任务删的仍是
     * 自己（NULL=当前任务）而非新任务，句柄不会被误用。 */
    vTaskDelete(NULL);
    /* unreachable */
}

/* ---------------- 公共 API ---------------- */

static void netif_tag(char out[3], const struct netif *n)
{
    out[0] = n ? n->name[0] : '?';
    out[1] = n ? n->name[1] : '?';
    out[2] = '\0';
}

esp_err_t pcapx_attach(const pcapx_config_t *cfg)
{
    esp_err_t ret;
    char ntag[3];
    bool sink_opened = false;

    /* --- 参数与状态检查（失败即拒绝，无需清理） ---
     * 注：attach/detach 属控制路径，未做相互间的并发互斥（单 console 会话使用），
     * 数据路径（tap/writer）与它们之间才是这里保证的同步关系 */
    if (cfg == NULL || cfg->netif == NULL || cfg->sink == NULL || cfg->sink->open == NULL ||
        cfg->sink->write == NULL || cfg->sink->close == NULL || cfg->sink->free_fn == NULL ||
        cfg->direction == 0 || (cfg->direction & ~(PCAPX_DIR_RX | PCAPX_DIR_TX)) != 0 ||
        cfg->snaplen == 0) {
        netif_tag(ntag, cfg ? cfg->netif : NULL);
        ESP_LOGE(TAG, "ATTACH_FAIL netif=%s reason=arg", ntag);
        return ESP_ERR_INVALID_ARG;
    }

    portENTER_CRITICAL(&s_lock);
    if (s_netif != NULL) {
        portEXIT_CRITICAL(&s_lock);
        netif_tag(ntag, cfg->netif);
        ESP_LOGE(TAG, "ATTACH_FAIL netif=%s reason=busy", ntag); /* 多 netif 并发为 non-goal */
        return ESP_ERR_INVALID_STATE;
    }
    portEXIT_CRITICAL(&s_lock);

    netif_tag(ntag, cfg->netif);
    if (!netif_is_up(cfg->netif) || cfg->netif->input == NULL || cfg->netif->linkoutput == NULL) {
        ESP_LOGE(TAG, "ATTACH_FAIL netif=%s reason=down", ntag);
        return ESP_ERR_INVALID_STATE;
    }

    /* --- 资源准备（失败走 cleanup） --- */
    size_t ring_bytes = cfg->ring_bytes ? cfg->ring_bytes : (size_t)CONFIG_PCAPX_RING_BYTES;
    s_ring = heap_caps_malloc(ring_bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    s_bounce = heap_caps_malloc(cfg->snaplen, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    s_writer_done = xSemaphoreCreateBinary();
    if (s_ring == NULL || s_bounce == NULL || s_writer_done == NULL) {
        ret = ESP_ERR_NO_MEM;
        ESP_LOGE(TAG, "ATTACH_FAIL netif=%s reason=no_mem", ntag);
        goto cleanup;
    }

    s_sink = cfg->sink; /* 所有权移交模块（detach 时 close+free） */
    ret = s_sink->open(s_sink);
    if (ret != ESP_OK) {
        /* 契约分工：SINK_OPEN_FAIL 的修复提示行（如 qemu -semihosting）由 sink
         * 实现自己打；core 只负责 ATTACH_FAIL reason=sink_open 这一层 */
        ESP_LOGE(TAG, "ATTACH_FAIL netif=%s reason=sink_open", ntag);
        goto cleanup;
    }
    sink_opened = true;

    /* pcap 全局头（24B，小端）：magic / ver 2.4 / thiszone 0 / sigfigs 0 /
     * snaplen / network=1(以太网)。头写失败折叠进 sink_open 报告：
     * sink 已 open 但写不动，对用户等价「不可用」 */
    {
        uint8_t ghdr[PCAPX_PCAP_GHDR_LEN] = {0};
        put_le32(&ghdr[0], PCAPX_PCAP_MAGIC);
        put_le16(&ghdr[4], 2);
        put_le16(&ghdr[6], 4);
        put_le32(&ghdr[16], cfg->snaplen);
        put_le32(&ghdr[20], PCAPX_PCAP_LINKTYPE_ETH);
        if (s_sink->write(s_sink, ghdr, sizeof(ghdr)) != ESP_OK) {
            ret = ESP_FAIL;
            ESP_LOGE(TAG, "ATTACH_FAIL netif=%s reason=sink_open", ntag);
            goto cleanup;
        }
    }

    /* --- 会话状态初始化（publish 顺序：先全部状态与 writer，最后换装+开 flag） --- */
    s_netif = cfg->netif;
    s_orig_input = cfg->netif->input;
    s_orig_linkoutput = cfg->netif->linkoutput;
    s_direction = cfg->direction;
    s_snaplen = cfg->snaplen;
    s_filter = cfg->filter;
    s_ring_size = ring_bytes;
    s_head = s_tail = 0;
    memset((void *)&s_stats, 0, sizeof(s_stats));
    s_inflight = 0;
    s_sink_err_logged = false;
    s_writer_handle = NULL;
    s_writer_run = true;
    s_enabled = false;

    {
        TaskHandle_t h = NULL;
        if (xTaskCreate(pcapx_task, "pcapx", CONFIG_PCAPX_WRITER_STACK, NULL,
                        CONFIG_PCAPX_WRITER_PRIO, &h) != pdPASS) {
            s_netif = NULL;
            ret = ESP_ERR_NO_MEM;
            ESP_LOGE(TAG, "ATTACH_FAIL netif=%s reason=no_mem", ntag);
            goto cleanup;
        }
        s_writer_handle = h; /* writer 此刻只可能阻塞在 take，不会先于 attach 返回退出 */
    }

    /* --- 换装（wrap 常驻；s_enabled 最后发布，tap 一开门看到的就是完整状态） --- */
    cfg->netif->input = pcapx_wrap_input;
    cfg->netif->linkoutput = pcapx_wrap_linkoutput;
    portENTER_CRITICAL(&s_lock);
    s_enabled = true;
    portEXIT_CRITICAL(&s_lock);

    ESP_LOGI(TAG, "ATTACH netif=%s mode=%s snap=%u sink=%s", ntag,
             cfg->direction == (PCAPX_DIR_RX | PCAPX_DIR_TX) ? "rx+tx"
                                                             : (cfg->direction == PCAPX_DIR_RX ? "rx" : "tx"),
             (unsigned)cfg->snaplen, s_sink->name);
    return ESP_OK;

cleanup:
    if (s_sink != NULL) {
        if (sink_opened) {
            s_sink->close(s_sink); /* open 成功过才 close，避免对未打开的 sink 重复失败 */
        }
        s_sink->free_fn(s_sink); /* 所有权已移交：无论哪一步失败都由 core 释放 */
        s_sink = NULL;
    }
    if (s_writer_done != NULL) {
        vSemaphoreDelete(s_writer_done);
        s_writer_done = NULL;
    }
    if (s_bounce != NULL) {
        heap_caps_free(s_bounce);
        s_bounce = NULL;
    }
    if (s_ring != NULL) {
        heap_caps_free(s_ring);
        s_ring = NULL;
    }
    return ret;
}

esp_err_t pcapx_detach(void)
{
    struct netif *n;

    portENTER_CRITICAL(&s_lock);
    n = s_netif;
    if (n == NULL) {
        portEXIT_CRITICAL(&s_lock);
        return ESP_ERR_INVALID_STATE;
    }
    s_enabled = false;
    portEXIT_CRITICAL(&s_lock);

    /* 恢复原始指针：新到帧直通原路径、不再进 wrap。竞态窗口（契约如实约束）：
     * 已越过 enable 检查的在飞 tap 仍会走完拷贝，由下面的 inflight 栅栏兜住，
     * 故建议在链路静默期调用（spec §3 设计决定） */
    n->input = s_orig_input;
    n->linkoutput = s_orig_linkoutput;

    while (s_inflight != 0) {
        taskYIELD(); /* 在飞 tap 尾部有界（≤ snaplen 拷贝），µs 级收敛 */
    }

    /* 停 writer：先置 run=false 再给通知——writer 醒来重查 flag 后走收尾路径 */
    s_writer_run = false;
    {
        TaskHandle_t w = s_writer_handle;
        if (w) {
            xTaskNotifyGive(w);
        }
    }
    xSemaphoreTake(s_writer_done, portMAX_DELAY); /* writer 完成排空 + sink close */

    pcapx_stats_t fin;
    portENTER_CRITICAL(&s_lock);
    fin = s_stats;
    memset((void *)&s_stats, 0, sizeof(s_stats)); /* 契约：未 attach 时 get_stats 全 0 */
    s_head = s_tail = 0;
    s_netif = NULL;
    portEXIT_CRITICAL(&s_lock);

    ESP_LOGI(TAG, "DETACH netif=%c%c rx=%u tx=%u drop=%u trunc=%u", n->name[0], n->name[1],
             (unsigned)fin.rx, (unsigned)fin.tx, (unsigned)fin.dropped, (unsigned)fin.truncated);

    /* 回收顺序：writer 已 close sink → core 只 free；环/弹床此刻无任何使用者 */
    s_sink->free_fn(s_sink);
    s_sink = NULL;
    heap_caps_free(s_ring);
    s_ring = NULL;
    s_ring_size = 0;
    heap_caps_free(s_bounce);
    s_bounce = NULL;
    vSemaphoreDelete(s_writer_done);
    s_writer_done = NULL;
    return ESP_OK;
}

bool pcapx_is_attached(void)
{
    portENTER_CRITICAL(&s_lock);
    bool r = (s_netif != NULL);
    portEXIT_CRITICAL(&s_lock);
    return r;
}

void pcapx_get_stats(pcapx_stats_t *out)
{
    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof(*out));
    portENTER_CRITICAL(&s_lock);
    if (s_netif != NULL) {
        *out = s_stats;
    }
    portEXIT_CRITICAL(&s_lock);
}
