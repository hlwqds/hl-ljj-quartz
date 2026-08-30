/*
 * main.c -- ch07：SysTick 心跳 + UART0 RX 中断驱动（环形缓冲）
 *
 * 目标机型：qemu-system-arm -M mps2-an385（Cortex-M3，num-irq=32）
 *
 * 两个实验共用一个映像（分离运行验证）：
 *   实验一  SysTick 100Hz 节拍，主循环每 100 tick 打一行 1Hz 心跳；
 *           ISR 只做 g_tick++，打印留给主循环——"ISR 短"军规的现场示范。
 *   实验二  UART0 RX 中断（IRQ0，mps2.c uartirq[0]=0）把字节塞进环形
 *           缓冲，主循环消费并按行回显统计；主循环空闲时 wfi 睡眠。
 *
 * 寄存器依据：
 *   - SysTick：ARMv7-M ARM（DDI 0403E.b）§B3.3，0xE000E010 起
 *   - NVIC：同上 §B3.4，ISER0=0xE000E100，IPR=0xE000E400（字节宽）
 *   - CMSDK APB UART：QEMU v10.1.5 hw/char/cmsdk-apb-uart.c
 *     CTRL bit3=RXINTEN，INTSTATUS(0x0C) W1C，读 DATA 只清 RXFULL
 */

#include <stdint.h>

/* ================= UART0（CMSDK APB，0x40004000）====================== */
#define UART0_BASE 0x40004000UL

#define UART0_DATA   (*(volatile uint32_t *)(UART0_BASE + 0x00))
#define UART0_STATE  (*(volatile uint32_t *)(UART0_BASE + 0x04))
#define UART0_CTRL   (*(volatile uint32_t *)(UART0_BASE + 0x08))
#define UART0_INTST  (*(volatile uint32_t *)(UART0_BASE + 0x0C))
#define UART0_DIV    (*(volatile uint32_t *)(UART0_BASE + 0x10))

#define UART_STATE_TXFULL  (1UL << 0)
#define UART_STATE_RXFULL  (1UL << 1)
#define UART_CTRL_TX_EN    (1UL << 0)
#define UART_CTRL_RX_EN    (1UL << 1)
#define UART_CTRL_RX_INTEN (1UL << 3) /* hw/char/cmsdk-apb-uart.c: R_CTRL_RXINTEN */
#define UART_INTST_RX      (1UL << 1) /* R_INTSTATUS_RX */

/* ================= SysTick（核内，0xE000E010）========================= */
#define SYST_CSR (*(volatile uint32_t *)0xE000E010UL)
#define SYST_RVR (*(volatile uint32_t *)0xE000E014UL)
#define SYST_CVR (*(volatile uint32_t *)0xE000E018UL)

#define SYST_CSR_ENABLE    (1UL << 0)
#define SYST_CSR_TICKINT   (1UL << 1)
#define SYST_CSR_CLKSOURCE (1UL << 2) /* 1 = 处理器时钟 25MHz（mps2.c SYSCLK_FRQ） */

/* ================= NVIC（核内，0xE000E100 起）========================= */
#define NVIC_ISER0 (*(volatile uint32_t *)0xE000E100UL) /* 写 1 使能，读回状态 */
#define NVIC_ICER0 (*(volatile uint32_t *)0xE000E180UL) /* 写 1 禁能（W1C）     */
#define NVIC_IPR   ((volatile uint8_t *)0xE000E400UL)   /* 每 IRQ 1 字节       */

#define UART0_RX_IRQ 0 /* mps2.c: uartirq[0] = 0（RX 在前，TX=RX+1） */

/* ================= 时钟 =============================================== */
#define SYSCLK_HZ 25000000UL  /* mps2.c: SYSCLK_FRQ，CLKSOURCE=1 时的节拍源 */
#define TICK_HZ   100UL       /* SysTick 100Hz——FreeRTOS 默认 tick 频率     */
/* 25_000_000 / 100 - 1 = 249_999，远小于 24 位上限 0xFFFFFF=16_777_215。
 * 若想要 1Hz 直接装 25M-1 会静默截断成 16_777_214（~0.67Hz）——24 位
 * 倒计数器的天花板，真机 F407 上 168MHz 时同理，软件分频是唯一解。   */

/* ================= 中断与主循环的共享状态 ============================= */
/* volatile：全部被 ISR 与主循环两侧读写，禁止编译器缓存到寄存器 */
static volatile uint32_t g_tick;     /* SysTick ISR ++，主循环读         */
static volatile uint32_t g_rx_irq;   /* RX ISR 进入次数（统计）           */
static volatile uint32_t g_rx_drop;  /* 环形缓冲满导致的丢字节计数       */

/* 环形缓冲：容量必须是 2 的幂，用掩码取模（M3 无硬件除法） */
#define RING_SIZE 32u
#define RING_MASK (RING_SIZE - 1u)

static volatile uint32_t g_head; /* 写指针：只归 RX ISR 动            */
static volatile uint32_t g_tail; /* 读指针：只归主循环动              */
static volatile uint8_t g_ring[RING_SIZE];

/* ================= 串口输出（主循环专用，ISR 不得碰）================== */
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

static void uart_putdec(uint32_t v)
{
    char buf[11];
    int i = 0;
    do {
        buf[i++] = (char)('0' + (v % 10));
        v /= 10;
    } while (v);
    while (i--)
        uart_putc(buf[i]);
}

/* ================= 实验一：SysTick 心跳 ================================ */
static void systick_init(void)
{
    SYST_RVR = SYSCLK_HZ / TICK_HZ - 1; /* 重装载值：249_999 */
    SYST_CVR = 0;                       /* 清当前值，首个周期从满装值起算 */
    /* 先配 RVR 再开 ENABLE|TICKINT|CLKSOURCE，顺序即文档推荐做法 */
    SYST_CSR = SYST_CSR_ENABLE | SYST_CSR_TICKINT | SYST_CSR_CLKSOURCE;
}

void SysTick_Handler(void) /* 向量表槽 15，强符号覆盖 startup.S 弱实现 */
{
    g_tick++; /* 军规示范：ISR 里只做这一次访存，其余全部留给主循环 */
}

/* ================= 实验二：UART0 RX 中断 + 环形缓冲 =================== */
static void uart0_irq_init(void)
{
    /* 1. NVIC 侧：设优先级（F407 实现高 4 位，QEMU M3 模型 8 位全实现，
     *    左移 4 位在两边都是"抢占优先级 2"的正确写法）+ 使能 IRQ0 */
    NVIC_IPR[UART0_RX_IRQ] = (uint8_t)(2u << 4);
    NVIC_ISER0 = (1UL << UART0_RX_IRQ); /* W1S：写 1 置位使能 */

    /* 2. 外设侧：RX 中断使能（TX 走轮询，不动它） */
    UART0_CTRL = UART_CTRL_TX_EN | UART_CTRL_RX_EN | UART_CTRL_RX_INTEN;
}

void UART0_RX_Handler(void) /* 向量表槽 16+0 = 异常号 16 */
{
    /* 顺序敏感（真实踩坑）：必须先 W1C 清挂起、再读 DATA。
     * 读 DATA 会让 QEMU 模型立刻送来下一个字节并重新置位 INTSTATUS.RX；
     * 若反过来（先读 DATA 再清挂起），夹在中间到达的那个字节的挂起
     * 标志会被这次 W1C 误清——通知永久丢失，该字节卡在接收缓冲里，
     * 后续所有字节跟着堵死。表现为"只回显第一个字符"。 */
    UART0_INTST = UART_INTST_RX;
    if (UART0_STATE & UART_STATE_RXFULL) {
        g_rx_irq++;
        uint8_t c = (uint8_t)UART0_DATA; /* 读 DATA 清 RXFULL，取走字节 */
        uint32_t h = g_head;
        if (h - g_tail >= RING_SIZE) { /* 缓冲满：宁可丢字节也要尽快返回 */
            g_rx_drop++;
        } else {
            g_ring[h & RING_MASK] = c;
            g_head = h + 1;
        }
    }
}

/* ================= 主循环 ============================================= */
/* UART 波特率初始化（ch04 同款） */
static void uart_init_common(void)
{
    UART0_CTRL = UART_CTRL_TX_EN | UART_CTRL_RX_EN;
    UART0_DIV = SYSCLK_HZ / 115200UL; /* = 217，QEMU 要求 16 <= BAUDDIV */
}

int main(void)
{
    uart_init_common();
    systick_init();
    uart0_irq_init();

    uart_puts("\r\nch07: systick + uart rx irq\r\n");
    uart_puts("SYST_RVR=");
    uart_putdec(SYST_RVR);
    uart_puts(" (tick=");
    uart_putdec(TICK_HZ);
    uart_puts("Hz)  UART0 RX=IRQ0 enabled\r\n");
    /* 让程序自己报 NVIC 状态：ISER0 读回 bit0=1、IPR[0]=0x20（优先级 2<<4） */
    uart_puts("ISER0=");
    uart_puthex(NVIC_ISER0);
    uart_puts(" IPR[0]=");
    uart_puthex(NVIC_IPR[UART0_RX_IRQ]);
    uart_puts(" (prio<<4)  VTOR=");
    uart_puthex(*(volatile uint32_t *)0xE000ED08UL);
    uart_puts("\r\n\r\n");

    uint32_t last_sec = 0xFFFFFFFFu; /* 故意不等值，让第一秒立即打印 */
    uint32_t line_bytes = 0;

    for (;;) {
        /* ---- 消费 A：SysTick 心跳（每 100 tick = 1s 一次）---- */
        uint32_t sec = g_tick / TICK_HZ;
        if (sec != last_sec) {
            last_sec = sec;
            uart_puts("[hb ] tick=");
            uart_putdec(g_tick);
            uart_puts(" sec=");
            uart_putdec(sec);
            uart_puts("\r\n");
        }

        /* ---- 消费 B：环形缓冲里的 RX 字节，按行回显统计 ---- */
        while (g_tail != g_head) {
            uint8_t c = g_ring[g_tail & RING_MASK];
            g_tail++;
            if (c == '\r' || c == '\n') {
                if (line_bytes) {
                    uart_puts("[rx ] line done: ");
                    uart_putdec(line_bytes);
                    uart_puts(" bytes, irq=");
                    uart_putdec(g_rx_irq);
                    uart_puts(" rxirq_total, drop=");
                    uart_putdec(g_rx_drop);
                    uart_puts("\r\n");
                    line_bytes = 0;
                }
            } else {
                uart_putc((char)c);
                line_bytes++;
            }
        }

        /* ---- 没活干了：睡觉，等任何一个中断唤醒（效率账的关键）---- */
        __asm volatile ("wfi");
    }
}
