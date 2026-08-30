/*
 * main.c -- ch08 定时器实验：SysTick 深入版 + CMSDK 双定时器双时基
 *
 * 目标机型：qemu-system-arm -M mps2-an385（Cortex-M3）
 *
 * 实验一：SysTick 轮询模式（TICKINT=0，不碰 NVIC）
 *   - COUNTFLAG 轮询打拍（1kHz 时基，5 x 200ms）
 *   - COUNTFLAG "读即清除"直接证据
 *   - 读 VAL（CVR）的回绕安全 delay_us + 三个时长的精确度测量
 *
 * 实验二：双时基并行
 *   - SysTick 换中断模式（1kHz，RTOS tick 姿势）驱动 g_ms 毫秒计数
 *   - CMSDK APB DualTimer Timer1 @ 0x40002000，32 位周期模式，
 *     LOAD = 25,000,000（TIMCLK = 25MHz -> 1Hz），IRQ10 -> NVIC
 *   - 主循环 250ms 心跳打印 dualtimer 倒计数值，两路时间戳交错
 *
 * 地址/IRQ/寄存器布局依据（QEMU v10.1.5 源码）：
 *   hw/arm/mps2.c:
 *     - armv7m cpuclk = SYSCLK = 25 MHz（SysTick CLKSOURCE=1 的数速）
 *     - armv7m refclk = 1 MHz（SysTick CLKSOURCE=0 的数速）
 *     - cmsdk-apb-timer0/1: 0x40000000 / 0x40001000, IRQ 8/9
 *     - cmsdk-apb-dualtimer: 0x40002000, IRQ 10（两路 timer 的合并中断）
 *   hw/timer/cmsdk-apb-dualtimer.c: LOAD/VALUE/CONTROL/INTCLR/RIS/MIS，
 *     CONTROL = ONESHOT(0) SIZE(1) PRESCALE(2..3) INTEN(5) MODE(6) ENABLE(7)
 *   hw/timer/armv7m_systick.c: CALIB.TENMS = refclk 的 10ms 计数 - 1
 *
 * 对应文章：《嵌入式硬件基础（八）：定时器——从 SysTick 心跳到 PWM 思想》
 */

#include <stdint.h>

/* ======================= UART0（同 ch04 模板） ======================= */

#define UART0_BASE 0x40004000UL
#define UART0_DATA  (*(volatile uint32_t *)(UART0_BASE + 0x00))
#define UART0_STATE (*(volatile uint32_t *)(UART0_BASE + 0x04))
#define UART0_CTRL  (*(volatile uint32_t *)(UART0_BASE + 0x08))
#define UART0_DIV   (*(volatile uint32_t *)(UART0_BASE + 0x10))

#define UART_STATE_TXFULL (1UL << 0)
#define UART_CTRL_TX_EN   (1UL << 0)
#define UART_CTRL_RX_EN   (1UL << 1)

#define SYSCLK_HZ 25000000UL
#define UART_BAUD 115200UL
#define UART_BAUDDIV (SYSCLK_HZ / UART_BAUD)

static void uart_init(void)
{
    UART0_CTRL = UART_CTRL_TX_EN | UART_CTRL_RX_EN;
    UART0_DIV = UART_BAUDDIV;
}

static void uart_putc(char c)
{
    while (UART0_STATE & UART_STATE_TXFULL)
        ;
    UART0_DATA = (uint32_t)c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void uart_puthex(uint32_t v)
{
    static const char hex[] = "0123456789abcdef";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

/* 无 libgcc 除法：div10 用 UMULL 常量乘法（M3 有 umull 指令） */
static uint32_t div10(uint32_t n)
{
    return (uint32_t)(((uint64_t)n * 0xCCCCCCCDULL) >> 35);
}

static void uart_putdec(uint32_t v)
{
    char buf[10];
    int i = 0;
    do {
        uint32_t q = div10(v);
        buf[i++] = (char)('0' + (v - q * 10));
        v = q;
    } while (v);
    while (i--)
        uart_putc(buf[i]);
}

/* ======================= SysTick（ARMv7-M PPB 区） ==================== */
/* 依据 ARMv7-M ARM（DDI 0403E.e）§B3.3 System timer, SysTick           */

#define SYST_CSR   (*(volatile uint32_t *)0xE000E010UL) /* 控制/状态     */
#define SYST_RVR   (*(volatile uint32_t *)0xE000E014UL) /* 重装值 24 位  */
#define SYST_CVR   (*(volatile uint32_t *)0xE000E018UL) /* 当前计数值    */
#define SYST_CALIB (*(volatile uint32_t *)0xE000E01CUL) /* 校准值        */

#define SYST_CSR_ENABLE    (1UL << 0)  /* 计数器使能                       */
#define SYST_CSR_TICKINT  (1UL << 1)   /* 数到 0 触发 SysTick 异常         */
#define SYST_CSR_CLKSRC   (1UL << 2)   /* 1=处理器时钟, 0=参考时钟         */
#define SYST_CSR_COUNTFLG (1UL << 16)  /* 数到 0 置位；读 CSR 即清零       */

/* mps2-an385：cpuclk = 25MHz。取 1kHz 时基：周期 = 25000 拍 = 1ms        */
#define CPU_HZ       25000000UL
#define TICKS_PER_US (CPU_HZ / 1000000UL)          /* 25 拍/us            */
#define SYST_RELOAD  (CPU_HZ / 1000UL - 1UL)       /* 24999               */

/* 中断模式的全局毫秒计数（实验二用；实验一 TICKINT=0 不受影响）        */
static volatile uint32_t g_ms;

void SysTick_Handler(void)
{
    g_ms++;
}

/* ============ CMSDK APB DualTimer Timer1（外设定时器） ================ */

#define DUALTIMER_BASE 0x40002000UL
#define DT1_LOAD   (*(volatile uint32_t *)(DUALTIMER_BASE + 0x00)) /* 重装 */
#define DT1_VALUE  (*(volatile uint32_t *)(DUALTIMER_BASE + 0x04)) /* 当前 */
#define DT1_CTRL   (*(volatile uint32_t *)(DUALTIMER_BASE + 0x08)) /* 控制 */
#define DT1_INTCLR (*(volatile uint32_t *)(DUALTIMER_BASE + 0x0C)) /* 清IRQ */
#define DT1_RIS    (*(volatile uint32_t *)(DUALTIMER_BASE + 0x10)) /* 裸态 */
#define DT1_MIS    (*(volatile uint32_t *)(DUALTIMER_BASE + 0x14)) /* 掩码态 */

#define DT_CTRL_ONESHOT   (1UL << 0)  /* 1=单次                         */
#define DT_CTRL_SIZE32    (1UL << 1)  /* 1=32 位计数, 0=16 位           */
#define DT_CTRL_PRESC_DIV1 (0UL << 2) /* 预分频 [3:2]: 0=/1             */
#define DT_CTRL_INTEN     (1UL << 5)  /* 中断使能                       */
#define DT_CTRL_PERIODIC  (1UL << 6)  /* 1=周期, 0=自由运行             */
#define DT_CTRL_ENABLE    (1UL << 7)  /* 使能计数                       */

#define DT_IRQ 10 /* 向量表槽位 16+10；NVIC ISER0 的 bit10              */

static volatile uint32_t g_dt_irqs;    /* dualtimer 中断次数             */
static volatile uint32_t g_dt_first_ms; /* 第 1 次中断的毫秒时间戳       */

/* ======================= NVIC（开 IRQ10） ============================ */

#define NVIC_ISER0 (*(volatile uint32_t *)0xE000E100UL)

/* --------------------- 实验一的 delay 原语 ------------------------- */

/*
 * 轮询版 delay：等 COUNTFLAG 置位（计数器数到 0 的瞬间）。
 * 特点：粒度 = 一个重装周期（本配置 1ms）；CPU 100% 忙等；不碰 NVIC。
 */
static void systick_delay_poll_1ms(void)
{
    while (!(SYST_CSR & SYST_CSR_COUNTFLG))
        ;
}

/*
 * 回绕安全的 delay_us：读 CVR 做减法。
 *
 * SysTick 是向下计数器：... 2 -> 1 -> 0 -> RELOAD -> RELOAD-1 ...
 * 回绕发生在 0 -> RELOAD 的跳变（不是 0xFFFFFF！），所以朴素写法
 *     while ((start - SYST_CVR) < ticks) ;        // BUG
 * 在 CVR 跳回 RELOAD 的瞬间差值会爆成一个巨大的无符号数，条件永假/永真
 * 不可控。两个对策：
 *   1) 按"同周期/跨周期"两种情况分别算已经流逝的拍数（systick_elapsed）；
 *   2) 单段等待不超过半个周期：等待退出条件 elapsed >= chunk 意味着
 *      "等待窗"宽度只有 (RELOAD+1-chunk) 拍——chunk 逼近整周期时窗口
 *      窄到一拍，轮询粒度粗一点就整窗跳过，循环白等一个周期。
 *      把 chunk 压到 <= (RELOAD+1)/2，窗口至少半周期宽，永不跳窗。
 */
static uint32_t systick_elapsed(uint32_t start)
{
    uint32_t cvr = SYST_CVR;
    if (start >= cvr)
        return start - cvr;                          /* 同一周期内       */
    return start + (SYST_RELOAD + 1UL) - cvr;        /* 刚跨过 0->RELOAD */
}

#define SYST_CHUNK_MAX ((SYST_RELOAD + 1UL) / 2UL) /* 12500：保证等待窗宽 */

static void delay_us(uint32_t us)
{
    uint32_t remaining = us * TICKS_PER_US;
    while (remaining) {
        uint32_t chunk = (remaining > SYST_CHUNK_MAX) ? SYST_CHUNK_MAX : remaining;
        uint32_t start = SYST_CVR;
        while (systick_elapsed(start) < chunk)
            ;
        remaining -= chunk;
    }
}

/*
 * 精确测量一段流逝时间：只读 CVR 不够——回绕后 start/cvr 的相对大小
 * 有二义性（差 1 拍还是差 1 个周期+1 拍？），必须请 COUNTFLAG 作证：
 * 它是电平保持的（数到 0 就置位，直到被读），绝不会漏数一次回绕。
 * 前提：被测时长 < 2 个周期（本实验最测 999us < 2ms，满足）。
 */
static uint32_t systick_measure(uint32_t start)
{
    uint32_t flag = SYST_CSR & SYST_CSR_COUNTFLG; /* 先读（读即清，防丢） */
    uint32_t cvr = SYST_CVR;
    if (flag)
        return start + (SYST_RELOAD + 1UL) - cvr; /* 恰好跨过一个回绕 */
    return start - cvr;                           /* 没跨过回绕           */
}

/* ==================================================================== */

int main(void)
{
    uart_init();

    /* ---------------- 实验一：SysTick 轮询模式 --------------------- */
    uart_puts("\r\n== ch08 exp1: SysTick polling (TICKINT=0) ==\r\n");

    SYST_CSR = 0;          /* 停表再配置，养成习惯                     */
    SYST_RVR = SYST_RELOAD;/* 24999: 周期 = 25000 拍 @ 25MHz = 1ms     */
    SYST_CVR = 0;          /* 任意写：清零计数器并清 COUNTFLAG          */
    SYST_CSR = SYST_CSR_ENABLE | SYST_CSR_CLKSRC; /* 0x5: 无 TICKINT   */

    uart_puts("CSR   = ");
    uart_puthex(SYST_CSR);
    uart_puts(" (ENABLE|CLKSOURCE, TICKINT=0)\r\n");
    uart_puts("CALIB = ");
    uart_puthex(SYST_CALIB);
    uart_puts(" (TENMS=9999: 10ms @ 1MHz refclk, no SKEW/NOREF)\r\n");

    /* 1a. COUNTFLAG 轮询打拍：5 x 200ms */
    uart_puts("poll 5 x 200ms by COUNTFLAG:\r\n  ");
    uint32_t flags = 0;
    for (uint32_t i = 1; i <= 5; i++) {
        for (uint32_t j = 0; j < 200; j++) {
            systick_delay_poll_1ms(); /* 每次读走一个置位的 COUNTFLAG */
            flags++;
        }
        uart_puts("t=");
        uart_putdec(i * 200);
        uart_puts("ms ");
    }
    uart_puts("\r\n  flags read = ");
    uart_putdec(flags);
    uart_puts(" (expect 1000)\r\n");

    /* 1b. COUNTFLAG 读即清除：读到 1 的那次读同时清零，紧接再读为 0 */
    uint32_t f1 = 0;
    do {
        f1 = SYST_CSR & SYST_CSR_COUNTFLG;
    } while (!f1);             /* 该次读返回 0x10000 并清零标志          */
    uint32_t f2 = SYST_CSR & SYST_CSR_COUNTFLG; /* 立即重读：已被清      */
    uart_puts("COUNTFLAG read-clear: first=");
    uart_puthex(f1);
    uart_puts(", immediate re-read=");
    uart_puthex(f2);
    uart_puts("\r\n");

    /* 1c. delay_us 精确度：读 CVR 测三次（期望值 + 调用开销几十拍）。
     *     先空跑一次热身：第一次执行该代码路径有取指/译码开销
     *     （QEMU 里是 TCG 首译码，实测约 1600 拍；真机对应 flash
     *     预取/cache miss，量级小得多）——热身后才量得到稳定值。   */
    delay_us(100);
#define MEASURE_US(us_)                                                    \
    do {                                                                   \
        uint32_t s_ = SYST_CVR;                                            \
        delay_us(us_);                                                     \
        uint32_t e_ = systick_measure(s_); /* flag 消歧后再谈精确 */       \
        uart_puts("delay_us(" #us_ ") = ");                                \
        uart_putdec(e_);                                                   \
        uart_puts(" ticks (ideal ");                                       \
        uart_putdec((uint32_t)(us_ * TICKS_PER_US));                       \
        uart_puts(")\r\n");                                                \
    } while (0)

    MEASURE_US(1);
    MEASURE_US(100);
    MEASURE_US(999);

    /* 1d. 宏观校准：1000 次 delay_us(1000)（= 1s）用 1kHz 标志计数     */
    SYST_CVR = 0; /* 对齐起点（同时清标志）                               */
    flags = 0;
    for (uint32_t i = 0; i < 1000; i++) {
        delay_us(1000);
        if (SYST_CSR & SYST_CSR_COUNTFLG)
            flags++;
    }
    uart_puts("1000 x delay_us(1000): flags=");
    uart_putdec(flags);
    uart_puts(" (expect ~1000)\r\n");

    /* ---------------- 实验二：双时基并行 --------------------------- */
    uart_puts("\r\n== ch08 exp2: dual timebase ==\r\n");

    /* 2a. SysTick 切中断模式：1kHz tick，模拟 RTOS 心跳               */
    SYST_CSR = 0;
    SYST_RVR = SYST_RELOAD;
    SYST_CVR = 0;
    g_ms = 0;

    /* 2b. CMSDK dualtimer Timer1: 1Hz，IRQ10                            */
    NVIC_ISER0 = (1UL << DT_IRQ);          /* NVIC 使能 IRQ10            */
    DT1_LOAD = CPU_HZ;                     /* 25,000,000 拍 = 1s         */
    DT1_CTRL = DT_CTRL_ENABLE | DT_CTRL_PERIODIC | DT_CTRL_SIZE32 |
               DT_CTRL_INTEN | DT_CTRL_PRESC_DIV1; /* 0xE2               */

    uart_puts("SysTick: 1kHz irq-mode tick (RTOS style), g_ms heartbeat\r\n");
    uart_puts("dualtimer: LOAD=25000000, CTRL=0xE2 (EN|PERIODIC|32B|INTEN)\r\n");
    uart_puts("every 250ms main prints dt VALUE; every 1s irq prints line\r\n");

    SYST_CSR = SYST_CSR_ENABLE | SYST_CSR_TICKINT | SYST_CSR_CLKSRC; /* 0x7 */

    /* 2c. 主循环：250ms 心跳 + 攒够 5 次 dualtimer 中断后打 summary    */
    uint32_t next_hb = 250;
    uint32_t dt_first = 0, dt_last = 0;
    int have_first = 0, summarized = 0;

    for (;;) {
        __asm volatile ("wfi");
        if (!summarized && g_ms >= next_hb) {
            uart_puts("[systick ms=");
            uart_putdec(next_hb);
            uart_puts("] dt.VALUE=");
            uart_putdec(DT1_VALUE);
            uart_puts("\r\n");
            next_hb += 250;
        }
        if (!have_first && g_dt_irqs >= 1) {
            have_first = 1;
            dt_first = g_dt_first_ms;
        }
        if (!summarized && g_dt_irqs >= 5) {
            dt_last = g_ms;
            summarized = 1;
            uart_puts("summary: 5 dt irqs, ms(first)=");
            uart_putdec(dt_first);
            uart_puts(" ms(last)=");
            uart_putdec(dt_last);
            uart_puts(" -> period=");
            uart_putdec((dt_last - dt_first) / 4);
            uart_puts("ms (expect 1000)\r\n");
            /* 打完 summary 静默：两个时基继续跑，但不再刷屏 */
        }
    }
}

/* ---------------- dualtimer IRQ10 处理函数 -------------------------- */

void CMSDK_DUALTIMER_IRQHandler(void)
{
    uint32_t value = DT1_VALUE; /* 先读：刚重装的倒计数值（自证在倒数）  */
    uint32_t now = g_ms;        /* 用 SysTick 时基给本次中断盖时间戳      */
    g_dt_irqs++;

    if (g_dt_irqs == 1) {
        g_dt_first_ms = now;
        uart_puts("[dt irq 1 @ ms=");
        uart_putdec(now);
        uart_puts("] VALUE=");
        uart_putdec(value);
        uart_puts(" RIS=");
        uart_putdec(DT1_RIS);
        uart_puts(" MIS=");
        uart_putdec(DT1_MIS);
        DT1_INTCLR = 1; /* 写 INTCLR 清标志（不写则中断电平不撤）        */
        uart_puts(" -> after-clear MIS=");
        uart_putdec(DT1_MIS);
        uart_puts("\r\n");
        return;
    }

    uart_puts("[dt irq ");
    uart_putdec(g_dt_irqs);
    uart_puts(" @ ms=");
    uart_putdec(now);
    uart_puts("] VALUE=");
    uart_putdec(value);
    uart_puts("\r\n");
    DT1_INTCLR = 1;
}
