/* eth_mdio_probe —— ch20《以太网上电：EMAC 与 PHY》配套实验固件
 *
 * 做通标准（章节原文）：
 *   ① MDIO 两线读出 PHY ID（LAN8720 预期 ID1=0x0007 ID2=0xC0Fx）；
 *   ② 插网线直连树莓派，PHY BSR 的 Link 位（bit2）从 0 变 1，拔线回落。
 *
 * 全寄存器级裸机（无 HAL/CubeMX）：时钟 HSE 25MHz→PLL 180MHz，
 * USART1 PA9/PA10 → CH340 → /dev/ttyUSB0 @115200，SysTick 1ms 心跳。
 * 纯轮询模型：不挂任何中断，ETH 收发留给 ch21 的 lwIP 工程。
 *
 * 寄存器坐标（RM0090 / 本机 CMSIS 头核对）：
 *   MAC 块 0x40028000：MACCR+00 MACMIIAR+10 MACMIIDR+14 MACA0HR+40 MACA0LR+44
 *   DMA 块 0x40029000：DMABMR+00 DMATPDR+04 DMARPDR+08 DMARDLAR+0C
 *                      DMATDLAR+10 DMASR+14 DMAOMR+18
 *   SYSCFG_PMC 0x40013804 bit23 = MII_RMII_SEL（先于 MAC 时钟使能，RM0090 顺序）
 */
#include <stdint.h>

typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t  u8;

#define REG32(a) (*(volatile u32 *)(a))
#define RM32(off) (REG32(0x40028000u + (off))) /* MAC 侧 */
#define RD32(off) (REG32(0x40029000u + (off))) /* DMA 侧 */

/* ---- RCC / FLASH / PWR ---- */
#define RCC_CR       REG32(0x40023800u)
#define RCC_PLLCFGR  REG32(0x40023804u)
#define RCC_CFGR     REG32(0x40023808u)
#define RCC_AHB1ENR  REG32(0x40023830u)
#define RCC_APB1ENR  REG32(0x40023840u)
#define RCC_APB2ENR  REG32(0x40023844u)
#define FLASH_ACR    REG32(0x40023C00u)
#define PWR_CR       REG32(0x40007000u)
#define SYSCFG_PMC   REG32(0x40013804u)

/* ---- GPIO ---- */
#define GPIOA_MODER  REG32(0x40020000u + 0x00)
#define GPIOA_OSPEEDR REG32(0x40020000u + 0x08)
#define GPIOA_PUPDR  REG32(0x40020000u + 0x0C)
#define GPIOA_AFRL   REG32(0x40020000u + 0x20)
#define GPIOA_AFRH   REG32(0x40020000u + 0x24)
#define GPIOC_MODER  REG32(0x40020800u + 0x00)
#define GPIOC_OSPEEDR REG32(0x40020800u + 0x08)
#define GPIOC_AFRL   REG32(0x40020800u + 0x20)
#define GPIOC_AFRH   REG32(0x40020800u + 0x24)
#define GPIOG_MODER  REG32(0x40021800u + 0x00)
#define GPIOG_OSPEEDR REG32(0x40021800u + 0x08)
#define GPIOG_AFRL   REG32(0x40021800u + 0x20)
#define GPIOG_AFRH   REG32(0x40021800u + 0x24)

/* ---- USART1（PA9/PA10，APB2） ---- */
#define USART1_SR    REG32(0x40011000u + 0x00)
#define USART1_DR    REG32(0x40011000u + 0x04)
#define USART1_BRR   REG32(0x40011000u + 0x08)
#define USART1_CR1   REG32(0x40011000u + 0x0C)

/* ---- SysTick / DWT ---- */
#define STK_CTRL     REG32(0xE000E010u)
#define STK_LOAD     REG32(0xE000E014u)

volatile u32 g_ms; /* SysTick 心跳（ch01 地基，半秒轮询的时基） */
void SysTick_Handler(void) { g_ms++; }

/* ================= UART ================= */
static void uart_init(u32 pclk2_hz)
{
    RCC_AHB1ENR |= 1u << 0;                        /* GPIOA */
    RCC_APB2ENR |= 1u << 4;                        /* USART1 */
    GPIOA_MODER = (GPIOA_MODER & ~(3u << 18)) | (2u << 18); /* PA9 AF */
    GPIOA_MODER = (GPIOA_MODER & ~(3u << 20)) | (2u << 20); /* PA10 AF */
    GPIOA_AFRH  = (GPIOA_AFRH & ~(0xFu << 4)) | (7u << 4);  /* PA9 AF7 */
    GPIOA_AFRH  = (GPIOA_AFRH & ~(0xFu << 8)) | (7u << 8);  /* PA10 AF7 */
    USART1_BRR  = pclk2_hz / 115200u;              /* OVER16 */
    USART1_CR1  = (1u << 13) | (1u << 3) | (1u << 2); /* UE|TE|RE */
}
static void putc_(char c) { while (!(USART1_SR & (1u << 7))) {} USART1_DR = (u32)(u8)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex(u32 v)
{
    const char *d = "0123456789abcdef";
    for (int i = 28; i >= 0; i -= 4) putc_(d[(v >> i) & 0xF]);
}
static void puthex16(u16 v) { puthex(v); }
static void putdec(u32 v)
{
    char b[11]; int i = 10; b[10] = 0;
    if (!v) { putc_('0'); return; }
    while (v && i) { b[--i] = (char)('0' + v % 10u); v /= 10u; }
    puts_(&b[i]);
}

/* ================= 时钟：HSE 25MHz → PLL → 180MHz =================
 * 六步配方（ch00e）：M=25 N=360 P=2 → VCO 360MHz /2 = 180MHz；
 * 180MHz@3.3V 需 5WS + VOS Scale1（F42x 特有，PWR_CR.VOS=11b）。 */
static void clock_init(void)
{
    RCC_CR |= 1u << 16;                            /* HSEON */
    while (!(RCC_CR & (1u << 17))) {}              /* HSERDY */
    FLASH_ACR = (5u << 0) | (1u << 8) | (1u << 9) | (1u << 10); /* 5WS|PRFTEN|ICEN|DCEN */
    RCC_APB1ENR |= 1u << 28;                       /* PWREN */
    PWR_CR |= 3u << 14;                            /* VOS[1:0]=11b Scale1（180MHz 前置） */
    RCC_CFGR = (RCC_CFGR & ~0xFC0Fu) | (4u << 13) | (5u << 10); /* HPRE=/1 PPRE2=/2 PPRE1=/4 */
    RCC_PLLCFGR = 25u | (360u << 6) | (1u << 22) | (8u << 24);  /* M25 N360 P2 Q8 SRC=HSE */
    RCC_CR |= 1u << 24;                            /* PLLON */
    while (!(RCC_CR & (1u << 25))) {}              /* PLLRDY */
    RCC_CFGR = (RCC_CFGR & ~3u) | 2u;              /* SW=PLL */
    while ((RCC_CFGR & (3u << 2)) != (2u << 2)) {} /* SWS=PLL */
}

/* ================= ETH（ch20 全套） ================= */
#define RX_DESC_N 4u
#define TX_DESC_N 4u
#define ETH_MAX  1536u /* MTU 1500 + 头余量 */

typedef struct { volatile u32 d0, d1, d2, d3; } desc_t;
/* 全在 SRAM(.bss)，绝不能进 CCM：ETH DMA 要直接读写 */
static desc_t rx_d[RX_DESC_N] __attribute__((aligned(4)));
static desc_t tx_d[TX_DESC_N] __attribute__((aligned(4)));
static u8 rx_b[RX_DESC_N][ETH_MAX] __attribute__((aligned(4)));
static u8 tx_b[TX_DESC_N][ETH_MAX] __attribute__((aligned(4)));

static u8 phy_addr = 0xFFu; /* 待核对：strap 决定；扫描兜底 */

/* MDIO 读：MACMIIAR 位打包 PA<<11 | MR<<6 | CR=100b(Div102)，MB 写 1 发车、轮询自清零 */
static u16 mdio_read(u8 phy, u8 reg)
{
    RM32(0x10) = ((u32)phy << 11) | ((u32)reg << 6) | (4u << 2); /* MW=0 读 */
    RM32(0x10) |= 1u;                                            /* MB=1 */
    while (RM32(0x10) & 1u) {}
    return (u16)RM32(0x14);
}
static void mdio_write(u8 phy, u8 reg, u16 val)
{
    RM32(0x14) = val;
    RM32(0x10) = ((u32)phy << 11) | ((u32)reg << 6) | (4u << 2) | (1u << 1) | 1u;
    while (RM32(0x10) & 1u) {}
}

/* RMII 九脚 AF11：PA1/PA2/PA7、PC1/PC4/PC5、PG11/PG13/PG14（板上走线待核对） */
static void rmii_gpio_af11_init(void)
{
    /* GPIOA：PA1 REF_CLK(入) PA2 MDIO(双向) PA7 CRS_DV(入) */
    GPIOA_MODER = (GPIOA_MODER & ~((3u << 2) | (3u << 4) | (3u << 14)))
                |  (2u << 2) | (2u << 4) | (2u << 14);
    GPIOA_OSPEEDR |= (3u << 2) | (3u << 4) | (3u << 14);
    GPIOA_PUPDR   = (GPIOA_PUPDR & ~(3u << 4)) | (1u << 4); /* PA2 MDIO 上拉 */
    GPIOA_AFRL    = (GPIOA_AFRL & ~0xF0000FF0u) | 0xB0000BB0u; /* PA1/2/7 AF11 */
    /* GPIOC：PC1 MDC(出) PC4 RXD0(入) PC5 RXD1(入) */
    GPIOC_MODER = (GPIOC_MODER & ~((3u << 2) | (3u << 8) | (3u << 10)))
                |  (2u << 2) | (2u << 8) | (2u << 10);
    GPIOC_OSPEEDR |= (3u << 2) | (3u << 8) | (3u << 10);
    GPIOC_AFRL    = (GPIOC_AFRL & ~0x00F000F0u) | 0x00B000B0u; /* PC1/4/5 AF11 */
    /* GPIOG：PG11 TX_EN(出) PG13 TXD0(出) PG14 TXD1(出) */
    GPIOG_MODER = (GPIOG_MODER & ~((3u << 22) | (3u << 26) | (3u << 28)))
                |  (2u << 22) | (2u << 26) | (2u << 28);
    GPIOG_OSPEEDR |= (3u << 22) | (3u << 26) | (3u << 28);
    GPIOG_AFRL    = (GPIOG_AFRL & ~0x0F0FF000u) | 0x0B0BB000u; /* PG11/13/14 AF11 */
}

static void eth_hw_init(void)
{
    /* 1) SYSCFG 先选 RMII，再开 ETH 时钟（RM0090 顺序，反了=静默死） */
    RCC_APB2ENR |= 1u << 14;                       /* SYSCFGEN */
    SYSCFG_PMC |= 1u << 23;                        /* MII_RMII_SEL=1 */
    RCC_AHB1ENR |= (7u << 25) | (1u << 0) | (1u << 2) | (1u << 6); /* ETH三时钟+GPIOA/C/G */
    rmii_gpio_af11_init();                         /* 2) 九脚 AF11 */
    RD32(0x00) |= 1u;                              /* 3) DMABMR.SR 软复位 */
    while (RD32(0x00) & 1u) {}
    /* 4) 描述符环上架：RCH/TCH=1 链表成环，RX 全部 OWN=1 交给 DMA */
    for (u32 i = 0; i < RX_DESC_N; i++) {
        rx_d[i].d1 = (1u << 14) | ETH_MAX;         /* RCH | RBS1 */
        rx_d[i].d2 = (u32)rx_b[i];
        rx_d[i].d3 = (u32)&rx_d[(i + 1u) % RX_DESC_N];
        rx_d[i].d0 = 0x80000000u;                  /* OWN=1 */
    }
    for (u32 i = 0; i < TX_DESC_N; i++) {
        tx_d[i].d0 = (1u << 20);                   /* TCH */
        tx_d[i].d2 = (u32)tx_b[i];
        tx_d[i].d3 = (u32)&tx_d[(i + 1u) % TX_DESC_N];
    }
    RD32(0x0C) = (u32)rx_d;                        /* DMARDLAR */
    RD32(0x10) = (u32)tx_d;                        /* DMATDLAR */
    /* 5) MAC：自造本地管理地址 12:34:56:78:9A:BC（首字节 bit1=1） */
    RM32(0x40) = 0x00001234u;                      /* MACA0HR */
    RM32(0x44) = 0x56789ABCu;                      /* MACA0LR */
    RM32(0x00) = (1u << 14) | (1u << 11) | (1u << 3) | (1u << 2); /* FES|DM|TE|RE */
    RD32(0x18) = (1u << 13) | (1u << 1);           /* DMAOMR：ST|SR 开张 */
}

static void phy_scan_and_reset(void)
{
    puts_("-- MDIO scan (reg2/3, addr 0..31) --\r\n");
    for (u8 a = 0; a < 32u; a++) {                 /* 一条 MDIO 最多挂 32 颗 PHY，逐址试探 */
        u16 id1 = mdio_read(a, 2), id2 = mdio_read(a, 3);
        if (id1 == 0xFFFFu || id1 == 0x0000u) continue; /* 悬空读全 1 / 无应答回 0 */
        puts_("phy "); putdec(a);
        puts_(" ID1=0x"); puthex16(id1);
        puts_(" ID2=0x"); puthex16(id2);
        puts_("\r\n");
        phy_addr = a;
    }
    if (phy_addr == 0xFFu) { puts_("no PHY found!\r\n"); return; }
    mdio_write(phy_addr, 0, 0x8000u);              /* BCR 软复位，写 1 自清零 */
    while (mdio_read(phy_addr, 0) & 0x8000u) {}
    mdio_write(phy_addr, 0, 0x1200u);              /* 自协商使能(bit12)+重启协商(bit9) */
}

/* BSR Link 位是「锁存低」设计：掉过链路会保持一次 0——连读两次取后值（ch20 术语卡） */
static u8 link_up(void)
{
    (void)mdio_read(phy_addr, 1);
    u16 bsr = mdio_read(phy_addr, 1);
    return (u8)((bsr >> 2) & 1u);
}

void main(void)
{
    clock_init();
    uart_init(90000000u);                          /* PLL 配定后 PCLK2=90MHz */
    puts_("\r\n=== eth_mdio_probe : ch20 EMAC+PHY ===\r\n");
    STK_LOAD = 180000u - 1u;                       /* HCLK 180MHz → 1ms tick */
    STK_CTRL = 7u;                                 /* ENABLE|TICKINT|CLKSOURCE */
    eth_hw_init();
    phy_scan_and_reset();

    puts_("MAC 12:34:56:78:9A:BC, MACCR=");
    puthex(RM32(0x00));                            /* 预期 0x0000408C */
    puts_(" DMARDLAR="); puthex(RD32(0x0C));       /* 预期 =rx_d 地址（nm 对账） */
    puts_("\r\nplug/unplug cable, watch link toggle...\r\n");

    u32 last = g_ms; u8 was_up = 0xFFu;
    for (;;) {
        if (phy_addr == 0xFFu) { continue; }       /* 没有 PHY 就静默等 gdb */
        if (g_ms - last >= 500u) {                 /* 半秒一轮询，只打印翻转 */
            last += 500u;
            u8 up = link_up();
            if (up != was_up) {
                u16 bsr = mdio_read(phy_addr, 1);
                puts_(up ? "link: UP   " : "link: DOWN ");
                puts_("BSR=0x"); puthex16(bsr);
                puts_(" autoneg="); putdec((u32)((bsr >> 5) & 1u));
                puts_("\r\n");
                was_up = up;
            }
        }
    }
}
