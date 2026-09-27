/* ethernetif.c —— lwIP 与 F429 ETH 之间的移植层（ch21「三件套」）
 *   low_level 三件：eth_hw_init（初始化）/ low_level_input（收）/ low_level_output（发）
 * 收发模型 = NO_SYS=1 轮询：main 循环调 ethernetif_poll，OWN 位=硬件与 CPU 的交接棒。
 * 硬件初始化部分与 ch20 的 eth_mdio_probe 同源（工程自含，刻意不抽公共库）。
 * 铁律：描述符与帧缓冲全在 .bss（SRAM 0x2000xxxx），CCM 是 DMA 走不进的房间。 */
#include <stdint.h>
#include "lwip/opt.h"
#include "lwip/def.h"
#include "lwip/mem.h"
#include "lwip/pbuf.h"
#include "lwip/stats.h"
#include "lwip/snmp.h"
#include "lwip/ethip6.h"
#include "netif/etharp.h"
#include "netif/ethernet.h"
#include "ethernetif.h"

typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t  u8;

#define REG32(a)  (*(volatile u32 *)(a))
#define RM32(off) (REG32(0x40028000u + (off))) /* MAC */
#define RD32(off) (REG32(0x40029000u + (off))) /* DMA */

/* ---- RCC / SYSCFG / GPIO（与 ch20 相同坐标） ---- */
#define RCC_AHB1ENR   REG32(0x40023830u)
#define RCC_APB2ENR   REG32(0x40023844u)
#define SYSCFG_PMC    REG32(0x40013804u)
#define GPIOA_MODER   REG32(0x40020000u + 0x00)
#define GPIOA_OSPEEDR REG32(0x40020000u + 0x08)
#define GPIOA_PUPDR   REG32(0x40020000u + 0x0C)
#define GPIOA_AFRL    REG32(0x40020000u + 0x20)
#define GPIOC_MODER   REG32(0x40020800u + 0x00)
#define GPIOC_OSPEEDR REG32(0x40020800u + 0x08)
#define GPIOC_AFRL    REG32(0x40020800u + 0x20)
#define GPIOG_MODER   REG32(0x40021800u + 0x00)
#define GPIOG_OSPEEDR REG32(0x40021800u + 0x08)
#define GPIOG_AFRL    REG32(0x40021800u + 0x20)

#define RX_DESC_N 4u
#define TX_DESC_N 4u
#define ETH_MAX   1536u /* MTU 1500 + 头余量 */

typedef struct { volatile u32 d0, d1, d2, d3; } desc_t;
/* 全在 SRAM(.bss)，绝不能进 CCM：ETH DMA 要直接读写（ch13 铁律） */
static desc_t rx_d[RX_DESC_N] __attribute__((aligned(4)));
static desc_t tx_d[TX_DESC_N] __attribute__((aligned(4)));
static u8 rx_b[RX_DESC_N][ETH_MAX] __attribute__((aligned(4)));
static u8 tx_b[TX_DESC_N][ETH_MAX] __attribute__((aligned(4)));

static u32 rx_cur, tx_cur;   /* CPU 侧游标：收/发各推各的 */
static u8  phy_addr = 0xFFu; /* strap 决定，扫描兜底 */

/* 自造本地管理地址 12:34:56:78:9A:BC（首字节 bit1=1；写 MACA0，netif 回抄） */
#define MAC_HR 0x00001234u
#define MAC_LR 0x56789ABCu

/* ================= MDIO（ch20 成果，这里只为 BSR 与扫描） ================= */
static u16 mdio_read(u8 phy, u8 reg)
{
    RM32(0x10) = ((u32)phy << 11) | ((u32)reg << 6) | (4u << 2);
    RM32(0x10) |= 1u;
    while (RM32(0x10) & 1u) {}
    return (u16)RM32(0x14);
}
static void mdio_write(u8 phy, u8 reg, u16 val)
{
    RM32(0x14) = val;
    RM32(0x10) = ((u32)phy << 11) | ((u32)reg << 6) | (4u << 2) | (1u << 1) | 1u;
    while (RM32(0x10) & 1u) {}
}

/* BSR Link 位是「锁存低」：掉过链路保持一次 0，连读两次取后值（ch20 术语卡） */
u8_t eth_link_poll(void)
{
    if (phy_addr == 0xFFu) { return 0; }
    (void)mdio_read(phy_addr, 1);
    return (u8_t)((mdio_read(phy_addr, 1) >> 2) & 1u);
}

/* ================= 硬件初始化（ch20 全套） ================= */
static void rmii_gpio_af11_init(void)
{
    GPIOA_MODER = (GPIOA_MODER & ~((3u << 2) | (3u << 4) | (3u << 14)))
                |  (2u << 2) | (2u << 4) | (2u << 14);        /* PA1/2/7 AF */
    GPIOA_OSPEEDR |= (3u << 2) | (3u << 4) | (3u << 14);
    GPIOA_PUPDR = (GPIOA_PUPDR & ~(3u << 4)) | (1u << 4);     /* MDIO 上拉 */
    GPIOA_AFRL  = (GPIOA_AFRL & ~0xF0000FF0u) | 0xB0000BB0u;  /* PA1/2/7 AF11 */
    GPIOC_MODER = (GPIOC_MODER & ~((3u << 2) | (3u << 8) | (3u << 10)))
                |  (2u << 2) | (2u << 8) | (2u << 10);        /* PC1/4/5 AF */
    GPIOC_OSPEEDR |= (3u << 2) | (3u << 8) | (3u << 10);
    GPIOC_AFRL  = (GPIOC_AFRL & ~0x00F000F0u) | 0x00B000B0u;  /* PC1/4/5 AF11 */
    GPIOG_MODER = (GPIOG_MODER & ~((3u << 22) | (3u << 26) | (3u << 28)))
                |  (2u << 22) | (2u << 26) | (2u << 28);      /* PG11/13/14 AF */
    GPIOG_OSPEEDR |= (3u << 22) | (3u << 26) | (3u << 28);
    GPIOG_AFRL  = (GPIOG_AFRL & ~0x0F0FF000u) | 0x0B0BB000u;  /* PG11/13/14 AF11 */
}

static void phy_scan_and_reset(void)
{
    for (u8 a = 0; a < 32u; a++) {
        u16 id1 = mdio_read(a, 2);
        if (id1 == 0xFFFFu || id1 == 0x0000u) { continue; }
        phy_addr = a; /* 扫到即锁地址（ID 可从串口 banner 侧核对，这里不打印省 UART） */
        break;
    }
    if (phy_addr == 0xFFu) { return; }
    mdio_write(phy_addr, 0, 0x8000u);          /* BCR 软复位 */
    while (mdio_read(phy_addr, 0) & 0x8000u) {}
    mdio_write(phy_addr, 0, 0x1200u);          /* 自协商使能+重启 */
}

void eth_hw_init(void)
{
    /* 1) SYSCFG 先选 RMII，再开 ETH 时钟（RM0090 顺序） */
    RCC_APB2ENR |= 1u << 14;
    SYSCFG_PMC |= 1u << 23;                    /* MII_RMII_SEL=1 */
    RCC_AHB1ENR |= (7u << 25) | (1u << 0) | (1u << 2) | (1u << 6);
    rmii_gpio_af11_init();
    RD32(0x00) |= 1u;                          /* DMABMR.SR 软复位 */
    while (RD32(0x00) & 1u) {}
    /* 2) 描述符环上架：RX 全部 OWN=1 交给 DMA；RCH/TCH 链表成环 */
    for (u32 i = 0; i < RX_DESC_N; i++) {
        rx_d[i].d1 = (1u << 14) | ETH_MAX;
        rx_d[i].d2 = (u32)rx_b[i];
        rx_d[i].d3 = (u32)&rx_d[(i + 1u) % RX_DESC_N];
        rx_d[i].d0 = 0x80000000u;
    }
    for (u32 i = 0; i < TX_DESC_N; i++) {
        tx_d[i].d0 = (1u << 20);               /* TCH */
        tx_d[i].d2 = (u32)tx_b[i];
        tx_d[i].d3 = (u32)&tx_d[(i + 1u) % TX_DESC_N];
    }
    RD32(0x0C) = (u32)rx_d;
    RD32(0x10) = (u32)tx_d;
    /* 3) MAC 地址 + 100M 全双工收发开张 */
    RM32(0x40) = MAC_HR;
    RM32(0x44) = MAC_LR;
    RM32(0x00) = (1u << 14) | (1u << 11) | (1u << 3) | (1u << 2); /* FES|DM|TE|RE */
    RD32(0x18) = (1u << 13) | (1u << 1);    /* DMAOMR：ST|SR */
    phy_scan_and_reset();
}

/* ================= RX：描述符环 → pbuf → netif->input ================= */
static void rx_rearm(u32 i)                    /* 还槽给 DMA：OWN=1，游标前进 */
{
    rx_d[i].d1 = (1u << 14) | ETH_MAX;
    rx_d[i].d0 = 0x80000000u;
    rx_cur = (rx_cur + 1u) % RX_DESC_N;
    RD32(0x08) = 1;                            /* DMARPDR：收包轮询需求，防 DMA 挂起 */
}

static struct pbuf *low_level_input(void)
{
    if (rx_d[rx_cur].d0 & 0x80000000u) { return NULL; } /* OWN 归 DMA：无货 */
    u32 i = rx_cur;
    u32 fl = (rx_d[i].d0 >> 16) & 0x3FFFu;     /* FL：帧长含 4B CRC */
    struct pbuf *p = NULL;
    if (fl >= 60u) {                           /* runt 残帧直接弃 */
        p = pbuf_alloc(PBUF_RAW, fl - 4u, PBUF_POOL); /* 去 CRC 交给栈 */
        if (p == NULL) {
            LINK_STATS_INC(link.memerr);
            LINK_STATS_INC(link.drop);
        } else {
            /* 拷贝派（章节 17.4 选型）：一跳 memcpy，环压力最小，拷完即还槽 */
            pbuf_take(p, rx_b[i], fl - 4u);
        }
    } else {
        LINK_STATS_INC(link.drop);
    }
    rx_rearm(i);
    return p;
}

void ethernetif_poll(struct netif *netif)
{
    struct pbuf *p;
    while ((p = low_level_input()) != NULL) {
        if (netif->input(p, netif) != ERR_OK) { /* 投递失败自回收：铁律 */
            LINK_STATS_INC(link.err);
            pbuf_free(p);
        }
    }
}

/* ================= TX：pbuf 链拼进连续 DMA 缓冲 ================= */
static err_t low_level_output(struct netif *netif, struct pbuf *p)
{
    while (tx_d[tx_cur].d0 & 0x80000000u) {}   /* OWN 未归：环满自旋（教学取舍，章节明言） */
    u32 i = tx_cur, n = 0;
    for (struct pbuf *q = p; q != NULL; q = q->next) {
        if (n + q->len > ETH_MAX) { break; }   /* 预算防御：绝不写溢出 DMA 缓冲 */
        u8 *dst = tx_b[i] + n;
        const u8 *src = q->payload;
        for (u32 k = 0; k < q->len; k++) { dst[k] = src[k]; }
        n += q->len;
    }
    tx_d[i].d1 = n;                            /* TBS1=帧长 */
    tx_d[i].d0 = (1u << 20) | (1u << 29) | (1u << 28) | 0x80000000u; /* TCH|FS|LS|OWN */
    RD32(0x04) = 1;                            /* DMATPDR：踢 TX DMA */
    tx_cur = (tx_cur + 1u) % TX_DESC_N;
    LINK_STATS_INC(link.xmit);
    MIB2_STATS_NETIF_ADD(netif, ifoutoctets, n);
    return ERR_OK;                             /* 满也绝不返回 ERR_MEM（errno 穿透事故，ch17 实验c） */
}

/* ================= lwIP 挂接口 ================= */
err_t ethernetif_init(struct netif *netif)
{
    netif->name[0] = 'e';
    netif->name[1] = 'n';
    netif->output = etharp_output;             /* IP 出口：ARP 全由栈代劳 */
    netif->linkoutput = low_level_output;      /* 唯一必须手写的发送函数 */
    netif->hwaddr_len = ETH_HWADDR_LEN;
    netif->hwaddr[0] = 0x12; netif->hwaddr[1] = 0x34; /* 与 MACA0HR/LR 一致的回抄 */
    netif->hwaddr[2] = 0x56; netif->hwaddr[3] = 0x78;
    netif->hwaddr[4] = 0x9A; netif->hwaddr[5] = 0xBC;
    netif->mtu = 1500;
    netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP |
                   NETIF_FLAG_ETHERNET | NETIF_FLAG_LINK_UP; /* Link 之后由 BSR 轮询动态喂 */
    return ERR_OK;
}
