/*
 * qemu_main.c -- ch05 QEMU 侧实证：MPS2 FPGAIO 点灯 + 读键 + 自由计数器
 *
 * 机型：qemu-system-arm -M mps2-an385（Cortex-M3）
 *
 * 模型考证（QEMU v10.1 源码，见文章 5.6 节）：
 *   hw/arm/mps2.c FPGA_AN385 分支：
 *     - FPGAIO 真模型，映射 0x40028000（sysbus_mmio_map(..., 0x40028000)）
 *     - "cmsdk-ahb-gpio" 0x40010000..0x40013000 只是
 *       create_unimplemented_device() 占位——名字像模型，行为是"吞写返 0"，
 *       配合 -d guest_errors 可看到 unimplemented device 日志（负向验证）
 *   hw/misc/mps2-fpgaio.c 寄存器表：
 *     +0x00 LED0     读写，bit_i = 用户 LED_i（num-leds=2）
 *     +0x08 BUTTON   只读恒 0——源码注释明说"不仿真用户按键"
 *     +0x10 CLK1HZ   只读，1Hz 自由计数器（虚拟时钟驱动）
 *     +0x14 CLK100HZ 只读，100Hz 自由计数器
 *   hw/char/cmsdk-apb-uart.c：UART0 0x40004000（沿用 ch04 模板）
 */

#include <stdint.h>

/* ---- CMSDK APB UART0（ch04 模板原样） ---- */
#define UART0_BASE 0x40004000UL
#define UART0_DATA  (*(volatile uint32_t *)(UART0_BASE + 0x00))
#define UART0_STATE (*(volatile uint32_t *)(UART0_BASE + 0x04))
#define UART0_CTRL  (*(volatile uint32_t *)(UART0_BASE + 0x08))
#define UART0_DIV   (*(volatile uint32_t *)(UART0_BASE + 0x10))

#define UART_STATE_TXFULL (1UL << 0)
#define UART_CTRL_TX_EN   (1UL << 0)
#define UART_CTRL_RX_EN   (1UL << 1)

#define SYSCLK_HZ 25000000UL /* mps2.c: SYSCLK_FRQ */
#define UART_BAUDDIV (SYSCLK_HZ / 115200UL)

static void uart_init(void)
{
    /* 先配分频、后开使能：QEMU 在 TX_EN 置位瞬间校验 bauddiv（>=16），
     * 顺序反了会打出 "Tx enabled with invalid baudrate"（guest error 日志实测）*/
    UART0_DIV = UART_BAUDDIV;
    UART0_CTRL = UART_CTRL_TX_EN | UART_CTRL_RX_EN;
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

/* ---- MPS2 FPGAIO @ 0x40028000（hw/misc/mps2-fpgaio.c） ---- */
#define FPGAIO_BASE 0x40028000UL

#define FPGAIO_LED0     (*(volatile uint32_t *)(FPGAIO_BASE + 0x00)) /* 用户 LED    */
#define FPGAIO_BUTTON   (*(volatile uint32_t *)(FPGAIO_BASE + 0x08)) /* 板上按键    */
#define FPGAIO_CLK1HZ   (*(volatile uint32_t *)(FPGAIO_BASE + 0x10)) /* 1Hz 计数器  */
#define FPGAIO_CLK100HZ (*(volatile uint32_t *)(FPGAIO_BASE + 0x14)) /* 100Hz 计数器*/

#define LED0_BIT 0 /* FPGAIO LED0 的 bit0 = USERLED0 */

/* ---- "cmsdk-ahb-gpio" 占位探针（0x40010000，负向验证用） ---- */
#define CMSDK_AHB_GPIO0_DATA (*(volatile uint32_t *)0x40010000UL)

static void delay_loops(volatile uint32_t n)
{
    while (n--)
        ;
}

int main(void)
{
    uart_init();

    uart_puts("\r\nch05 gpio on qemu mps2-an385 (fpgaio 0x40028000)\r\n");

    /* ---- 1. LED：写 LED0 -> 读回。等价于 F407 的 BSRR 写 -> ODR 读 ---- */
    FPGAIO_LED0 = 0; /* 全灭 */
    uart_puts("[1] LED0 <- 0x0        readback ");
    uart_puthex(FPGAIO_LED0);
    uart_puts("\r\n");

    FPGAIO_LED0 = 1UL << LED0_BIT; /* bit0 = USERLED0 亮 */
    uart_puts("[1] LED0 <- 0x1        readback ");
    uart_puthex(FPGAIO_LED0);
    uart_puts("\r\n");

    /* ---- 2. 闪 5 次（F407 点灯循环的 QEMU 等价物） ---- */
    uart_puts("[2] blink x5 ");
    for (int i = 0; i < 5; i++) {
        FPGAIO_LED0 = 1UL << LED0_BIT;
        delay_loops(20000000);
        FPGAIO_LED0 = 0;
        delay_loops(20000000);
        uart_putc('.');
    }
    uart_puts(" done (final LED0=");
    uart_puthex(FPGAIO_LED0);
    uart_puts(")\r\n");

    /* ---- 3. 按键：BUTTON 恒 0（模型不仿真，源码注释原话） ---- */
    uart_puts("[3] BUTTON readback   ");
    uart_puthex(FPGAIO_BUTTON);
    uart_puts(" (QEMU 不仿真按键, 恒 0)\r\n");

    /* ---- 4. 可观察的"输入"：100Hz 自由计数器，隔段时间读两次 ---- */
    uint32_t c1 = FPGAIO_CLK100HZ;
    delay_loops(20000000); /* 约 0.1s 量级（TCG 下按宿主机速度跑） */
    uint32_t c2 = FPGAIO_CLK100HZ;
    uart_puts("[4] CLK100HZ t0=");
    uart_puthex(c1);
    uart_puts(" t1=");
    uart_puthex(c2);
    uart_puts(" delta=");
    uart_puthex(c2 - c1);
    uart_puts("\r\n");

    /* ---- 5. 负向验证：写"cmsdk-ahb-gpio"占位设备，读回必为 0 ----
     * （跑 QEMU 加 -d guest_errors 可看到 unimplemented device 日志） */
    CMSDK_AHB_GPIO0_DATA = 0x0000A55AUL;
    uart_puts("[5] stub 0x40010000 <- 0xa55a readback ");
    uart_puthex(CMSDK_AHB_GPIO0_DATA);
    uart_puts(" (unimplemented: 吞写返 0)\r\n");

    uart_puts("done\r\n");

    /* 结束态：LED 留亮，wfi 等中断（此刻无中断源，即安静停机） */
    FPGAIO_LED0 = 1UL << LED0_BIT;
    for (;;)
        __asm volatile ("wfi");
}
