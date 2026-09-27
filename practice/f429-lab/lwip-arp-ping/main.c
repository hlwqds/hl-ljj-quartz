/* lwip_arp_ping —— ch21《裸机 lwIP：不带 OS 的协议栈》配套实验固件
 *
 * 三步走（章节原文）：
 *   ① NO_SYS=1 轮询模型 bring-up（main 循环 = 事件循环）；
 *   ② 静态 IP 10.42.0.10 直连树莓派（10.42.0.20）发第一声 ARP——RPi 侧
 *      `sudo tcpdump -i eth0 -n -e 'arp or icmp'` 亲眼看到 who-has/is-at；
 *   ③ ping 双向通：RPi→F429 是 lwIP 本能回（LWIP_ICMP=1 零应用代码），
 *      F429→RPi 是 raw pcb 手搓 ICMP echo，DWT->CYCCNT 量 RTT。
 *
 * 全寄存器级裸机 + lwIP 2.2.0（vendor 在 lwip-src/）：时钟 180MHz，
 * USART1 PA9/PA10 → CH340 → /dev/ttyUSB0 @115200，SysTick 1ms 喂 sys_now()。
 */
#include <stdint.h>
#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/timeouts.h"
#include "lwip/ip_addr.h"
#include "lwip/raw.h"
#include "lwip/icmp.h"
#include "lwip/inet_chksum.h"
#include "lwip/stats.h"
#include "lwip/etharp.h"
#include "netif/ethernet.h"
#include "ethernetif.h"

typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t  u8;

#define REG32(a)  (*(volatile u32 *)(a))
#define DEMCR     REG32(0xE000EDFCu)   /* bit24 TRCENA */
#define DWT_CTRL  REG32(0xE0001000u)   /* bit0  CYCCNTENA */
#define DWT_CYCCNT REG32(0xE0001004u)

/* ---- RCC / USART1 / SysTick（与 ch20 工程同款坐标） ---- */
#define RCC_CR        REG32(0x40023800u)
#define RCC_PLLCFGR   REG32(0x40023804u)
#define RCC_CFGR      REG32(0x40023808u)
#define RCC_AHB1ENR   REG32(0x40023830u)
#define RCC_APB1ENR   REG32(0x40023840u)
#define RCC_APB2ENR   REG32(0x40023844u)
#define FLASH_ACR     REG32(0x40023C00u)
#define PWR_CR        REG32(0x40007000u)
#define USART1_SR     REG32(0x40011000u + 0x00)
#define USART1_DR     REG32(0x40011000u + 0x04)
#define USART1_BRR    REG32(0x40011000u + 0x08)
#define USART1_CR1    REG32(0x40011000u + 0x0C)
#define GPIOA_MODER   REG32(0x40020000u + 0x00)
#define GPIOA_AFRH    REG32(0x40020000u + 0x24)
#define STK_CTRL      REG32(0xE000E010u)
#define STK_LOAD      REG32(0xE000E014u)

volatile u32 g_ms;
void SysTick_Handler(void) { g_ms++; }

static void uart_init(u32 pclk2_hz)
{
    RCC_AHB1ENR |= 1u << 0;
    RCC_APB2ENR |= 1u << 4;
    GPIOA_MODER = (GPIOA_MODER & ~(3u << 18)) | (2u << 18);
    GPIOA_MODER = (GPIOA_MODER & ~(3u << 20)) | (2u << 20);
    GPIOA_AFRH  = (GPIOA_AFRH & ~(0xFu << 4)) | (7u << 4);
    GPIOA_AFRH  = (GPIOA_AFRH & ~(0xFu << 8)) | (7u << 8);
    USART1_BRR  = pclk2_hz / 115200u;
    USART1_CR1  = (1u << 13) | (1u << 3) | (1u << 2);
}
static void putc_(char c) { while (!(USART1_SR & (1u << 7))) {} USART1_DR = (u32)(u8)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void putdec(u32 v)
{
    char b[11]; int i = 10; b[10] = 0;
    if (!v) { putc_('0'); return; }
    while (v && i) { b[--i] = (char)('0' + v % 10u); v /= 10u; }
    puts_(&b[i]);
}

/* HSE 25MHz → PLL ×360/2 = 180MHz（六步配方，ch00e；5WS + VOS Scale1 前置） */
static void clock_init(void)
{
    RCC_CR |= 1u << 16;
    while (!(RCC_CR & (1u << 17))) {}
    FLASH_ACR = (5u << 0) | (1u << 8) | (1u << 9) | (1u << 10);
    RCC_APB1ENR |= 1u << 28;
    PWR_CR |= 3u << 14;
    RCC_CFGR = (RCC_CFGR & ~0xFC0Fu) | (4u << 13) | (5u << 10);
    RCC_PLLCFGR = 25u | (360u << 6) | (1u << 22) | (8u << 24);
    RCC_CR |= 1u << 24;
    while (!(RCC_CR & (1u << 25))) {}
    RCC_CFGR = (RCC_CFGR & ~3u) | 2u;
    while ((RCC_CFGR & (3u << 2)) != (2u << 2)) {}
}

static void dwt_init(void) /* 手搓 ping 的秒表：180 周期 = 1µs */
{
    DEMCR |= 1u << 24;     /* TRCENA */
    DWT_CYCCNT = 0;
    DWT_CTRL |= 1u;        /* CYCCNTENA */
}

/* ================= NO_SYS=1 全部「线程」：下面的 main 循环 ================= */
static struct netif g_netif;
static struct raw_pcb *ping_pcb;
static u32 g_t0;                                  /* 发出 echo request 的周期记账 */

static const ip4_addr_t *rpi_ip(void)             /* 10.42.0.20：树莓派直连端 */
{
    static ip4_addr_t ip;
    static u8 done = 0;
    if (!done) { IP4_ADDR(&ip, 10, 42, 0, 20); done = 1; }
    return &ip;
}

/* raw 回调：收到 echo reply。回调即临界区——快进快出，只打印与回收 */
static u8_t ping_recv(void *arg, struct raw_pcb *pcb, struct pbuf *p, const ip_addr_t *addr)
{
    (void)arg; (void)pcb; (void)addr;
    if (p != NULL && p->len >= 8) {
        const u8 *h = p->payload;
        puts_("[ping] reply seq="); putdec((u32)((h[6] << 8) | h[7]));
        puts_(" rtt_us="); putdec((DWT_CYCCNT - g_t0) / 180u); puts_("\r\n");
    }
    pbuf_free(p);
    return 1;                                     /* 已消费，不再上送 */
}

static u16 seq;
static void ping_send(const ip4_addr_t *dst)
{
    struct pbuf *p = pbuf_alloc(PBUF_IP, 8, PBUF_RAM);
    if (p == NULL) { return; }
    u8 *h = p->payload;
    h[0] = 8; h[1] = 0; h[2] = 0; h[3] = 0;       /* type=echo request, cksum 后填 */
    h[4] = 0xF4; h[5] = 0x29;                     /* id=0xF429：tcpdump payload 里可辨 */
    h[6] = (u8)(seq >> 8); h[7] = (u8)seq++;
    u16 c = inet_chksum(h, 8);                    /* lwIP 白送的标准校验和 */
    h[2] = (u8)(c >> 8); h[3] = (u8)c;
    g_t0 = DWT_CYCCNT;                            /* 记账发出时刻，recv 侧算 RTT */
    raw_sendto(ping_pcb, p, dst);
    pbuf_free(p);
}

static void app_tick(void)
{
    static u32 t_link, t_arp, t_ping, t_stats;
    static u8  was_up = 0xFFu;

    if (g_ms - t_link >= 500u) {                  /* Link 由 BSR 轮询喂进 netif */
        t_link += 500u;
        u8 up = eth_link_poll();
        if (up != was_up) {
            puts_(up ? "[link] UP\r\n" : "[link] DOWN\r\n");
            if (up) { netif_set_link_up(&g_netif); } else { netif_set_link_down(&g_netif); }
            was_up = up;
        }
    }
    if (!was_up) { return; }                      /* 链路没通，下面都免谈 */

    if (g_ms - t_arp >= 1000u) {                  /* 第一声 ARP（并持续刷新邻居表） */
        t_arp += 1000u;
        etharp_query(&g_netif, rpi_ip(), NULL);   /* q=NULL：纯 ARP request */
    }
    if (g_ms - t_ping >= 1000u) {                 /* 手搓 ping：F429 → RPi */
        t_ping += 1000u;
        ping_send(rpi_ip());
    }
    if (g_ms - t_stats >= 30000u) {               /* pbuf/mem 有没有漏（清单#3） */
        t_stats += 30000u;
        puts_("---- lwip stats ----\r\n");
        stats_display();
    }
}

int main(void)
{
    clock_init();
    uart_init(90000000u);                         /* PLL 配定后 PCLK2=90MHz */
    puts_("\r\n=== lwip_arp_ping : ch21 bare-metal lwIP (NO_SYS=1) ===\r\n");
    STK_LOAD = 180000u - 1u;                      /* HCLK 180MHz → 1ms tick → sys_now */
    STK_CTRL = 7u;
    dwt_init();

    eth_hw_init();                                /* ch20 成果：硬件邮箱上架 */
    lwip_init();                                  /* NO_SYS 下它就是全部初始化 */

    ip4_addr_t ip, nm, gw;                        /* 裸机版 `ip addr add 10.42.0.10/24` */
    IP4_ADDR(&ip, 10, 42, 0, 10);
    IP4_ADDR(&nm, 255, 255, 255, 0);
    IP4_ADDR(&gw, 10, 42, 0, 20);
    netif_add(&g_netif, &ip, &nm, &gw, NULL, ethernetif_init, ethernet_input);
    netif_set_default(&g_netif);
    netif_set_up(&g_netif);                       /* Link 状态稍后由 BSR 轮询喂入 */

    ping_pcb = raw_new(IP_PROTO_ICMP);            /* 手搓 ping 的协议控制块 */
    raw_recv(ping_pcb, ping_recv, NULL);
    raw_bind(ping_pcb, &g_netif.ip_addr);

    puts_("netif en0  MAC 12:34:56:78:9A:BC  IP 10.42.0.10/24\r\n");
    puts_("peer  10.42.0.20 (RPi): tcpdump -i eth0 -n -e 'arp or icmp'\r\n");
    puts_("loop: poll rx -> sys_check_timeouts -> app_tick\r\n");

    for (;;) {
        ethernetif_poll(&g_netif);                /* RX：OWN 归 CPU 的帧 → pbuf → 栈 */
        sys_check_timeouts();                     /* ARP/定时器口粮：没人替你喂 */
        app_tick();                               /* link/ARP/ping/统计 */
    }
}
