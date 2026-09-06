/*
 * RCC 三连读取器：把《从 HSI 到 HCLK》章的 openocd `mdw 0x40023800 3` 验尸术
 * 变成固件——先读时钟树算出真实 PCLK2，再据此配波特率，最后把三寄存器
 * 逐位解码打印到 USART1（PA9/PA10 → CH340 → /dev/ttyUSB0 @115200）。
 *
 * 不改任何时钟配置：读到什么就是什么（上电 HSI 也好、bootloader/前级固件
 * 配好的 180MHz 也好，都能正确打印——波特率随树自适应）。
 *
 * 真机预期（本板 clock_init 之后的典型值）：
 *   RCC_CR=0x03035883  RCC_PLLCFGR=0x07405A19  RCC_CFGR=0x0000940A
 *   => SYSCLK/HCLK=180MHz PCLK1=45MHz PCLK2=90MHz
 */
#define RCC_BASE     0x40023800UL
#define RCC_CR       (*(volatile unsigned int *)(RCC_BASE + 0x00))
#define RCC_PLLCFGR  (*(volatile unsigned int *)(RCC_BASE + 0x04))
#define RCC_CFGR     (*(volatile unsigned int *)(RCC_BASE + 0x08))
#define RCC_AHB1ENR  (*(volatile unsigned int *)(RCC_BASE + 0x30))
#define RCC_APB2ENR  (*(volatile unsigned int *)(RCC_BASE + 0x44))

#define GPIOA_BASE   0x40020000UL
#define GPIOA_MODER  (*(volatile unsigned int *)(GPIOA_BASE + 0x00))
#define GPIOA_AFRH   (*(volatile unsigned int *)(GPIOA_BASE + 0x24))

#define USART1_BASE  0x40011000UL
#define USART1_SR    (*(volatile unsigned int *)(USART1_BASE + 0x00))
#define USART1_DR    (*(volatile unsigned int *)(USART1_BASE + 0x04))
#define USART1_BRR   (*(volatile unsigned int *)(USART1_BASE + 0x08))
#define U1_CR1       (*(volatile unsigned int *)(USART1_BASE + 0x0C))

/* SysTick（核内 PPB，ch00e 第 7 节的住址） */
#define STK_CTRL     (*(volatile unsigned int *)0xE000E010UL)
#define STK_LOAD     (*(volatile unsigned int *)0xE000E014UL)
#define STK_VAL      (*(volatile unsigned int *)0xE000E018UL)

typedef unsigned int u32;

/* ---------- 时钟树探测：只读，不改 ---------- */
typedef struct {
    u32 cr, pllcfgr, cfgr;
    unsigned pll_m, pll_n, pll_p, pll_q, pll_src_hse;
    unsigned sws;                 /* 0=HSI 1=HSE 2=PLL 3=非法 */
    unsigned src_hz, sysclk, hclk, pclk1, pclk2;
    unsigned ahb_div, apb1_div, apb2_div;
} tree_t;

static unsigned ahb_div_of(u32 cfgr) /* HPRE[7:4] */
{
    unsigned h = (cfgr >> 4) & 0xF;
    if (h < 8) return 1;
    return 1u << (h - 7);         /* 1000->2 ... 1111->512 */
}
static unsigned apb_div_of(u32 p)   /* PPRE[12:10]/[15:13] */
{
    if (p < 4) return 1;
    return 1u << (p - 3);         /* 100->2 101->4 110->8 111->16 */
}

static void tree_probe(tree_t *t)
{
    t->cr = RCC_CR; t->pllcfgr = RCC_PLLCFGR; t->cfgr = RCC_CFGR;
    t->pll_m = t->pllcfgr & 0x3F;
    t->pll_n = (t->pllcfgr >> 6) & 0x1FF;
    unsigned p = (t->pllcfgr >> 16) & 3;
    t->pll_p = 2u * (p + 1);      /* 00->2 01->4 10->6 11->8 */
    t->pll_q = (t->pllcfgr >> 24) & 0xF;
    t->pll_src_hse = (t->pllcfgr >> 22) & 1;
    t->sws = (t->cfgr >> 2) & 3;  /* 硬件回显：当前真跑在谁上 */

    unsigned pll_hz = 0;
    if (t->pll_m) {               /* 防 0 除（QEMU 未实现 RCC 时读回 0） */
        unsigned in = t->pll_src_hse ? 25000000u : 16000000u;
        pll_hz = in / t->pll_m * t->pll_n / t->pll_p;
    }
    t->src_hz  = t->sws == 2 ? pll_hz : (t->sws == 1 ? 25000000u : 16000000u);
    t->ahb_div = ahb_div_of(t->cfgr);
    t->apb1_div = apb_div_of((t->cfgr >> 10) & 7);
    t->apb2_div = apb_div_of((t->cfgr >> 13) & 7);
    t->sysclk = t->src_hz;
    t->hclk  = t->sysclk / t->ahb_div;
    t->pclk1 = t->hclk / t->apb1_div;
    t->pclk2 = t->hclk / t->apb2_div;
}

/* ---------- UART：按探测到的 PCLK2 配波特率 ---------- */
static void uart_init(unsigned pclk2_hz)
{
    RCC_AHB1ENR |= 1u << 0;                       /* GPIOA 时钟 */
    RCC_APB2ENR |= 1u << 4;                       /* USART1 时钟（挂 APB2） */
    GPIOA_MODER = (GPIOA_MODER & ~(3u << 18)) | (2u << 18); /* PA9 -> AF */
    GPIOA_AFRH  = (GPIOA_AFRH & ~(0xFu << 4)) | (7u << 4);  /* AF7=USART1 */
    USART1_BRR  = pclk2_hz / 115200u;             /* OVER16：BRR=fpclk/波特率 */
    U1_CR1 = (1u << 13) | (1u << 3);              /* UE | TE */
}
static void putc_(char c) { while (!(USART1_SR & (1u << 7))) {} USART1_DR = (u32)(unsigned char)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex(u32 v)
{
    const char *d = "0123456789abcdef";
    puts_("0x");
    for (int i = 28; i >= 0; i -= 4) putc_(d[(v >> i) & 0xF]);
}
static void putdec(unsigned v)
{
    char b[11]; int i = 10; b[10] = 0;
    if (!v) { putc_('0'); return; }
    while (v && i) { b[--i] = '0' + v % 10; v /= 10; }
    puts_(&b[i]);
}

static void report(tree_t *t)
{
    static const char *sws_name[] = { "HSI", "HSE", "PLL", "?" };
    puts_("\r\n=== RCC 三连 @ 0x40023800 ===\r\n");
    puts_("RCC_CR     = "); puthex(t->cr);
    puts_("  HSI:");  puts_((t->cr & (1u << 1)) ? "RDY " : "-   ");
    puts_(" HSE:");  puts_((t->cr & (1u << 17)) ? "RDY " : "-   ");
    puts_(" PLL:");  puts_((t->cr & (1u << 25)) ? "LOCKED" : "-");
    puts_("\r\nRCC_PLLCFGR= "); puthex(t->pllcfgr);
    puts_("  M="); putdec(t->pll_m);
    puts_(" N=");  putdec(t->pll_n);
    puts_(" P=/"); putdec(t->pll_p);
    puts_(" Q=/"); putdec(t->pll_q);
    puts_(" SRC="); puts_(t->pll_src_hse ? "HSE" : "HSI");
    puts_("\r\nRCC_CFGR   = "); puthex(t->cfgr);
    puts_("  SWS="); puts_(sws_name[t->sws]);
    puts_(" HPRE=/"); putdec(t->ahb_div);
    puts_(" PPRE1=/"); putdec(t->apb1_div);
    puts_(" PPRE2=/"); putdec(t->apb2_div);
    puts_("\r\n=> SYSCLK="); putdec(t->sysclk / 1000000u);
    puts_("MHz HCLK="); putdec(t->hclk / 1000000u);
    puts_("MHz PCLK1="); putdec(t->pclk1 / 1000000u);
    puts_("MHz PCLK2="); putdec(t->pclk2 / 1000000u); puts_("MHz");
    puts_("\r\nSysTick: CTRL="); puthex(STK_CTRL);
    puts_(" LOAD="); puthex(STK_LOAD);
    if ((STK_CTRL & 1u) && STK_LOAD) {          /* ENABLE 且已配：给出 tick 频率账 */
        unsigned clk = (STK_CTRL & (1u << 2)) ? t->hclk : t->hclk / 8u;
        puts_(" => tick=");
        putdec(clk / (STK_LOAD + 1u)); puts_("Hz");
    }
    puts_("\r\n");
}

void main(void)
{
    tree_t t;
    tree_probe(&t);        /* 1. 先读树（在任何打印之前） */
    uart_init(t.pclk2);    /* 2. 按真实 PCLK2 配波特率——树错也能打 */
    report(&t);            /* 3. 打印三连解码 */
    for (;;) { __asm volatile("wfi"); }
}
