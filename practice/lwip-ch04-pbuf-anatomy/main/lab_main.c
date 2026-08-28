/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（四）实验工程：pbuf 深拆
 *
 * 基于第三章的 openeth 联网模板（bring-up 部分与 ch3 完全一致），
 * 网络就绪后依次执行三组实验：
 *   E1 四种 pbuf 类型分配实测：
 *      PBUF_RAM / PBUF_POOL / PBUF_ROM / PBUF_REF 分别 pbuf_alloc，
 *      打印结构体地址、payload 地址、type_internal、ref、len/tot_len，
 *      并验证 IDF 全堆化下 POOL 与 RAM 同样来自 libc 堆（地址段对比）。
 *   E2 链式结构可视化：
 *      手动构造多 pbuf 链（cat/chain），遍历打印
 *      类型/len/tot_len/ref，演示 tot_len 递推不变量与 ref 共享语义；
 *      附收包方向剥头序列（pbuf_remove_header）真实指针移动。
 *   E3 故障注入（pbuf 分配压力）：
 *      C1 池上限探针：连续分配 PBUF_POOL 直到越过「名义池大小」仍成功；
 *      C2 堆耗尽探针：持续持有直到 pbuf_alloc 返回 NULL，记录临界点；
 *      C3 网络可见故障：持有大量 pbuf 挤压堆空间时跑 ping，
 *        观察丢包/失败，随后全部释放观察协议栈自愈。
 *
 * 版注记：本 IDF（v6.0.2，lwIP 2.2.0-dev）中池大小宏名是 PBUF_POOL_SIZE
 * （上游 2.1.x 遗留名）；MEMP_NUM_PBUF_POOL 是更晚上游的重命名，
 * 在本仓库源码中并不存在。且 MEMP_MEM_MALLOC=1 时 pool 计数上限只对
 * MEMP_TCP_PCB 有显式补丁计数（见 src/core/memp.c 的 ESP_LWIP 段），
 * PBUF_POOL 不设防——本实验 C1 用实测证明这一点。
 */

#include <stdio.h>
#include <string.h>
#include <assert.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_heap_caps.h"

#include "lwip/opt.h"
#include "lwip/pbuf.h"
#include "lwip/udp.h"
#include "lwip/inet.h"
#include "lwip/prot/ethernet.h"
#include "ping/ping_sock.h"

static const char *TAG = "ch4lab";

#define DHCP_TIMEOUT_MS  10000

/* 便于在一块保持期内持有/释放的槽位数 */
#define HOLD_MAX 400

static SemaphoreHandle_t s_got_ip;
static esp_ip4_addr_t s_ip, s_nm, s_gw;
static struct pbuf *s_held[HOLD_MAX];

/* ============================ 事件处理（同 ch3 模板） ============================ */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    switch (event_id) {
    case ETHERNET_EVENT_START:
        ESP_LOGI(TAG, "ETH_EVENT: START");
        break;
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "ETH_EVENT: CONNECTED (link up)");
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGI(TAG, "ETH_EVENT: DISCONNECTED (link down)");
        break;
    case ETHERNET_EVENT_STOP:
    default:
        break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    s_ip = evt->ip_info.ip;
    s_nm = evt->ip_info.netmask;
    s_gw = evt->ip_info.gw;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR "/" IPSTR " gw " IPSTR,
             IP2STR(&s_ip), IP2STR(&s_nm), IP2STR(&s_gw));
    xSemaphoreGive(s_got_ip);
}

/* ============================ 小工具 ============================ */

/* 去掉 const 的规范姿势（ROM payload 传给 pbuf_alloc_reference(void*) 用） */
static inline void *discard_const(const void *p)
{
    return (void *)(uintptr_t)p;
}

/* 按 ESP32 典型地址段粗分内存区域（QEMU 与真机布局一致） */
static const char *addr_region(uintptr_t a)
{
    if (a >= 0x3F400000UL && a < 0x3F800000UL) {
        return "flash(DROM)";
    }
    if (a >= 0x3FF00000UL && a < 0x40000000UL) {
        return "int-DRAM";
    }
    return "?";
}

/* type_internal 低字节还原为可读类型名
 * （pbuf.h 枚举被截断到 u8_t 后的实际驻留值，对照 E1 实测） */
static const char *ti_type_name(u8_t ti)
{
    switch (ti & 0xFF) {
    case PBUF_TYPE_FLAG_STRUCT_DATA_CONTIGUOUS:       return "RAM";  /* 0x80 */
    case PBUF_TYPE_ALLOC_SRC_MASK_STD_MEMP_PBUF:      return "ROM";  /* 0x01 */
    case PBUF_TYPE_FLAG_DATA_VOLATILE |
         PBUF_TYPE_ALLOC_SRC_MASK_STD_MEMP_PBUF:      return "REF";  /* 0x41 */
    case PBUF_TYPE_FLAG_STRUCT_DATA_CONTIGUOUS |
         PBUF_TYPE_ALLOC_SRC_MASK_STD_MEMP_PBUF_POOL: return "POOL"; /* 0x82 */
    default:                                          return "?";
    }
}

static size_t heap_free(void)
{
    return heap_caps_get_free_size(MALLOC_CAP_8BIT);
}

static size_t heap_largest(void)
{
    return heap_caps_get_largest_free_block(MALLOC_CAP_8BIT);
}

/*
 * 遍历打印一条 pbuf 链——输出即文章「链结构图」的机器底稿：
 * 每行一个节点：结构体地址、next、类型、len/tot_len/ref、payload 及其偏移。
 */
static void dump_chain(const char *tag, const struct pbuf *head)
{
    int i = 0;
    for (const struct pbuf *q = head; q != NULL; q = q->next, i++) {
        printf("[%s] %s p#%d @%p next=%p | %s ti=%02Xh len=%u tot_len=%u ref=%u | payload=%p off=%ld\n",
               tag, i == 0 ? "==>" : "   ->", i,
               (const void *)q, (const void *)q->next,
               ti_type_name(q->type_internal), q->type_internal,
               q->len, q->tot_len, q->ref,
               q->payload,
               (long)((u8_t *)q->payload - (u8_t *)q));
    }
    fflush(stdout);
}

/* ============================ E1: 四类型分配实测 ============================ */

/* flash 常量区（DROM）中的零拷贝数据源 */
static const char s_rom_payload[] =
    "ROM-PAYLOAD-zero-copy-from-flash-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";

static void exp_a_types(void)
{
    ESP_LOGI(TAG, "--- E1: alloc one payload of each of the four types ---");
    printf("[E1] sizeof(struct pbuf)=%u  SIZEOF_STRUCT_PBUF(align)=%u  "
           "PBUF_POOL_BUFSIZE(align)=%u\n",
           (unsigned)sizeof(struct pbuf),
           (unsigned)LWIP_MEM_ALIGN_SIZE(sizeof(struct pbuf)),
           (unsigned)LWIP_MEM_ALIGN_SIZE(PBUF_POOL_BUFSIZE));
    printf("[E1] layer enum values: RAW=%d LINK=%d IP=%d TRANSPORT=%d\n",
           (int)PBUF_RAW, (int)PBUF_LINK, (int)PBUF_IP, (int)PBUF_TRANSPORT);

    size_t free_before = heap_free();

    /* RAM: TX 主力，struct+payload 一整块连续 mem_malloc */
    struct pbuf *ram = pbuf_alloc(PBUF_TRANSPORT, 200, PBUF_RAM);
    /* POOL: RX 主力，「池」元素逐个取（IDF 下实为 mem_malloc） */
    struct pbuf *pool = pbuf_alloc(PBUF_TRANSPORT, 200, PBUF_POOL);
    /* ROM: 引用 flash 常量数据（struct 来自 MEMP_PBUF） */
    struct pbuf *rom = pbuf_alloc_reference(discard_const(s_rom_payload),
                                            sizeof(s_rom_payload) - 1, PBUF_ROM);
    /* REF: 引用外部易变 RAM 数据 */
    char volatile_buf[200];
    memset(volatile_buf, 'R', sizeof(volatile_buf));
    struct pbuf *ref = pbuf_alloc_reference(volatile_buf, 200, PBUF_REF);

    struct pbuf *all[4] = { ram, pool, rom, ref };
    const char *names[4] = { "RAM ", "POOL", "ROM ", "REF " };
    for (int i = 0; i < 4; i++) {
        if (all[i] == NULL) {
            printf("[E1] %-4s FAILED (NULL)\n", names[i]);
            continue;
        }
        printf("[E1] %-4s pbuf@%p ti=%02Xh ref=%u len=%u tot_len=%u "
               "payload@%p(%s) payload-pbuf=%ld struct_region=%s\n",
               names[i], (void *)all[i], all[i]->type_internal, all[i]->ref,
               all[i]->len, all[i]->tot_len,
               all[i]->payload, addr_region((uintptr_t)all[i]->payload),
               (long)((u8_t *)all[i]->payload - (u8_t *)all[i]),
               addr_region((uintptr_t)all[i]));
    }
    printf("[E1] heap free delta after 4 allocs=%ld B (before=%u)\n",
           (long)((long)free_before - (long)heap_free()), (unsigned)free_before);

    /* layer 参数决定预留头空间：同为 PBUF_RAM、length=64，仅换 layer */
    ESP_LOGI(TAG, "--- E1b: PBUF_RAM headroom grows with layer ---");
    pbuf_layer layers[4] = { PBUF_RAW, PBUF_LINK, PBUF_IP, PBUF_TRANSPORT };
    struct pbuf *lr[4];
    for (int i = 0; i < 4; i++) {
        lr[i] = pbuf_alloc(layers[i], 64, PBUF_RAM);
        if (lr[i]) {
            printf("[E1b] layer_enum=%d payload_offset_from_data_start=%ld "
                   "len=%u tot_len=%u heap_alloc=~%ld B\n",
                   (int)layers[i],
                   (long)((u8_t *)lr[i]->payload -
                          ((u8_t *)lr[i] + LWIP_MEM_ALIGN_SIZE(sizeof(struct pbuf)))),
                   lr[i]->len, lr[i]->tot_len,
                   (long)(LWIP_MEM_ALIGN_SIZE(sizeof(struct pbuf)) +
                          LWIP_MEM_ALIGN_SIZE((int)layers[i]) +
                          LWIP_MEM_ALIGN_SIZE(64)));
        }
    }

    pbuf_free(ram);
    pbuf_free(pool);
    pbuf_free(rom);
    pbuf_free(ref);
    for (int i = 0; i < 4; i++) {
        pbuf_free(lr[i]);
    }
    printf("[E1] after free-all heap free=%u delta_vs_start=%ld\n",
           (unsigned)heap_free(), (long)((long)free_before - (long)heap_free()));
    fflush(stdout);
}

/* ============================ E2: 链式结构与引用语义 ============================ */

static void exp_b_chain(void)
{
    ESP_LOGI(TAG, "--- E2: build a chain and watch tot_len / ref ---");

    /* 步骤 1: 一条典型 TX 组合链——RAM 头部(带 IP 层预留) + ROM 用户数据 */
    struct pbuf *hdr = pbuf_alloc(PBUF_IP, 20, PBUF_RAM);   /* 将装 IP 头 */
    struct pbuf *dat = pbuf_alloc_reference(discard_const(s_rom_payload),
                                            60, PBUF_ROM);  /* 用户数据 */
    dump_chain("E2.separate", hdr);
    dump_chain("E2.separate", dat);

    /* pbuf_cat: 接管调用者对 tail 的引用（此后不得再单独使用 dat） */
    pbuf_cat(hdr, dat);
    dump_chain("E2.after-cat", hdr);

    /* 步骤 2: ref 共享。第二条链也挂上同一个 tail（chain 内部会 pbuf_ref） */
    struct pbuf *hdr2 = pbuf_alloc(PBUF_IP, 8, PBUF_RAM);
    pbuf_chain(hdr2, hdr->next);            /* hdr->next 就是 dat */
    printf("[E2] shared tail: expect dat ref=2, chain1 intact\n");
    dump_chain("E2.chain2", hdr2);
    dump_chain("E2.chain1", hdr);

    /* 步骤 3: 释放第二条链——pbuf_free 沿链递减，碰到 ref>0 即停 */
    u8_t freed = pbuf_free(hdr2);
    printf("[E2] pbuf_free(chain2 head) freed %u pbuf(s); dat survives:\n", freed);
    dump_chain("E2.after-free2", hdr);

    /* 步骤 4: 收包方向的剥头序列（对应文章 4.5 节）：伪造一张
     * eth(14)+ip(20)+udp(8)+data 的入帧，按栈的真实顺序逐层剥头 */
    u8_t frame[SIZEOF_ETH_HDR + 20 + UDP_HLEN + 32];
    memcpy(frame, "\xff\xff\xff\xff\xff\xff\x52\x54\x00\x12\x34\x56\x08\x00",
           SIZEOF_ETH_HDR);
    struct pbuf *rx = pbuf_alloc(PBUF_RAW, sizeof(frame), PBUF_RAM);
    memcpy(rx->payload, frame, sizeof(frame));
    rx->len = rx->tot_len = sizeof(frame);
    dump_chain("E2.rx-frame", rx);
    int r1 = pbuf_remove_header(rx, SIZEOF_ETH_HDR);  /* ethernet_input 剥以太网头 */
    printf("[E2] strip ETH(%d): rc=%d payload@%p len=%u tot_len=%u\n",
           (int)SIZEOF_ETH_HDR, r1, rx->payload, rx->len, rx->tot_len);
    int r2 = pbuf_remove_header(rx, 20);              /* ip4_input(无选项 IHL=5) */
    printf("[E2] strip IP(20): rc=%d payload@%p len=%u tot_len=%u\n",
           r2, rx->payload, rx->len, rx->tot_len);
    int r3 = pbuf_remove_header(rx, UDP_HLEN);        /* udp_input 剥 UDP 头 */
    printf("[E2] strip UDP(%d): rc=%d payload@%p len=%u tot_len=%u <- app data starts here\n",
           (int)UDP_HLEN, r3, rx->payload, rx->len, rx->tot_len);

    pbuf_free(rx);
    pbuf_free(hdr);
    fflush(stdout);
}

/* ============================ E3: 故障注入 ============================ */

typedef struct { uint32_t ok; uint32_t fail; uint32_t create_fail; } ping_stat_t;

static void ping_cb_ok(esp_ping_handle_t hdl, void *args)
{
    ping_stat_t *st = (ping_stat_t *)args;
    st->ok++;
}

static void ping_cb_timeout(esp_ping_handle_t hdl, void *args)
{
    ping_stat_t *st = (ping_stat_t *)args;
    st->fail++;
}

/* 发 count 个 ICMP echo 给网关，回调统计；阻塞至会话结束。
 * 若会话本身都创建不出（内存饥饿），置 create_fail 并按全失败计。 */
static void run_ping_round(int count, ping_stat_t *st)
{
    st->ok = st->fail = st->create_fail = 0;
    ip_addr_t target;
    IP_SET_TYPE_VAL(target, IPADDR_TYPE_V4);
    ip4_addr_set_u32(ip_2_ip4(&target), s_gw.addr);

    esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
    cfg.target_addr = target;
    cfg.count = count;
    cfg.interval_ms = 100;
    cfg.timeout_ms = 900;

    esp_ping_callbacks_t cbs = {
        .cb_args = st,
        .on_ping_success = ping_cb_ok,
        .on_ping_timeout = ping_cb_timeout,
    };
    esp_ping_handle_t hdl = NULL;
    if (esp_ping_new_session(&cfg, &cbs, &hdl) != ESP_OK) {
        st->create_fail = 1;
        st->fail += count;
        return;
    }
    esp_ping_start(hdl);
    vTaskDelay(pdMS_TO_TICKS(count * cfg.interval_ms + 3 * cfg.timeout_ms));
    esp_ping_stop(hdl);
    esp_ping_delete_session(hdl);
}

/* 从 s_held[from_index] 起连续持有 want 个 PBUF_POOL，返回实际持有数 */
static int hold_pool_pbufs(int want, int from_index)
{
    int got = 0;
    for (int i = from_index; i < from_index + want && i < HOLD_MAX; i++) {
        s_held[i] = pbuf_alloc(PBUF_RAW, 512, PBUF_POOL);
        if (s_held[i] == NULL) {
            break;
        }
        got++;
    }
    return got;
}

static int release_held(int upto)
{
    int freed = 0;
    for (int i = 0; i < upto; i++) {
        if (s_held[i]) {
            pbuf_free(s_held[i]);
            s_held[i] = NULL;
            freed++;
        }
    }
    return freed;
}

static void exp_c_pressure(void)
{
    ping_stat_t st;

    ESP_LOGI(TAG, "--- E3.C0: baseline ping gw ---");
    run_ping_round(10, &st);
    printf("[C0] baseline ping: ok=%lu fail=%lu heap_free=%u largest=%u\n",
           (unsigned long)st.ok, (unsigned long)st.fail,
           (unsigned)heap_free(), (unsigned)heap_largest());

    /* C1: 池上限探针——一口气越过名义池大小 PBUF_POOL_SIZE(默认16) */
    ESP_LOGI(TAG, "--- E3.C1: pool-cap probe: 48 consecutive PBUF_POOL allocs ---");
    int held = hold_pool_pbufs(48, 0);
    for (int i = 15; i < held; i += 16) {     /* 跨越第 16/32/48 个关口的样本 */
        printf("[C1] held[%d]=%p alive past nominal cap #%d\n",
               i, (void *)s_held[i], i + 1);
    }
    printf("[C1] result: %d consecutive non-NULL PBUF_POOL allocs "
           "(nominal PBUF_POOL_SIZE=%d)\n", held, PBUF_POOL_SIZE);

    /* C2: 堆耗尽探针——继续追加直到第一个 NULL */
    ESP_LOGI(TAG, "--- E3.C2: keep holding until pbuf_alloc returns NULL ---");
    size_t free_before_more = heap_free();
    int more = hold_pool_pbufs(HOLD_MAX - held, held);
    int total_held = held + more;
    printf("[C2] added %d more pool pbufs consuming %ld B (%ld B each avg)\n",
           more, (long)((long)free_before_more - (long)heap_free()),
           more ? (long)(((long)free_before_more - (long)heap_free()) / more) : 0L);
    if (total_held < HOLD_MAX) {
        printf("[C2] FIRST NULL at total_held=%d; now heap_free=%u largest_blk=%u\n",
               total_held + 1, (unsigned)heap_free(), (unsigned)heap_largest());
        printf("[C2] confirm starvation, re-alloc -> %s\n",
               pbuf_alloc(PBUF_RAW, 512, PBUF_POOL) ? "non-NULL?!" : "NULL");
    } else {
        printf("[C2] reached hold-slot limit (%d) before heap exhaustion\n", HOLD_MAX);
    }
    printf("[C2] network still functional under max hold? baseline check below\n");

    /* C3: 高水位跑 ping 看网络症状，然后阶梯式释放观察「自愈阈值」 */
    ESP_LOGI(TAG, "--- E3.C3: ping at high watermark (%d held), then step-release ---",
             total_held);
    run_ping_round(10, &st);
    printf("[C3] attempt#0: held=%d heap_free=%u ok=%lu fail=%lu create_fail=%lu\n",
           total_held, (unsigned)heap_free(),
           (unsigned long)st.ok, (unsigned long)st.fail,
           (unsigned long)st.create_fail);

    /* 每次放 20 个再试，直到一轮完全成功（会话建成且 reply 全收到）——
     * 那个数字就是本机配置下的经验自愈阈值。 */
    for (int attempt = 1; total_held > 0; attempt++) {
        int n = release_held(20);
        total_held -= n;
        run_ping_round(10, &st);
        printf("[C3] attempt#%d: freed=%d held=%d heap_free=%u ok=%lu fail=%lu create_fail=%lu\n",
               attempt, n, total_held, (unsigned)heap_free(),
               (unsigned long)st.ok, (unsigned long)st.fail,
               (unsigned long)st.create_fail);
        if (!st.create_fail && st.ok == 10 && st.fail == 0) {
            break;
        }
    }

    release_held(HOLD_MAX);
    printf("[C3] ALL RELEASED: heap_free back to %u\n", (unsigned)heap_free());
    run_ping_round(10, &st);
    printf("[C3] recovery ping: ok=%lu fail=%lu heap_free=%u\n",
           (unsigned long)st.ok, (unsigned long)st.fail, (unsigned)heap_free());
    fflush(stdout);
}

/* ============================ app_main：bring-up + 实验 ============================ */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch4 lab: pbuf anatomy ==");

    /* —— bring-up 与 ch3 模板一致 —— */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num = -1;
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac != NULL);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    assert(phy != NULL);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));

    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout -- check QEMU -nic and events");
        return;
    }
    printf("[BOOT] network ready: heap_free=%u\n", (unsigned)heap_free());

    memset(s_held, 0, sizeof(s_held));

    exp_a_types();
    exp_b_chain();
    exp_c_pressure();

    ESP_LOGI(TAG, "== ch4 lab done ==");
    printf("[DONE] all experiments finished\n");
    fflush(stdout);
}
