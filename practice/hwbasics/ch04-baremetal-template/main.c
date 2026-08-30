/*
 * main.c -- 裸机 main：0 依赖直写 UART0 寄存器，打出第一行输出
 *
 * 目标机型：qemu-system-arm -M mps2-an385（Cortex-M3）
 * UART：CMSDK APB UART，基址与寄存器布局依据 QEMU 源码
 *       hw/char/cmsdk-apb-uart.c（v10.1），UART0 = 0x40004000。
 */

#include <stdint.h>

/* ---- CMSDK APB UART0（QEMU hw/arm/mps2.c: uartbase[0] = 0x40004000） ---- */
#define UART0_BASE 0x40004000UL

#define UART0_DATA  (*(volatile uint32_t *)(UART0_BASE + 0x00)) /* 发送/接收数据 */
#define UART0_STATE (*(volatile uint32_t *)(UART0_BASE + 0x04)) /* 状态位        */
#define UART0_CTRL  (*(volatile uint32_t *)(UART0_BASE + 0x08)) /* 使能控制      */
#define UART0_DIV   (*(volatile uint32_t *)(UART0_BASE + 0x10)) /* 波特率分频    */

#define UART_STATE_TXFULL (1UL << 0) /* 发送缓冲满，写入前必须轮询      */
#define UART_CTRL_TX_EN   (1UL << 0) /* 发送使能                        */
#define UART_CTRL_RX_EN   (1UL << 1) /* 接收使能                        */

/* mps2-an385 的 UART 时钟 = SYSCLK = 25 MHz（hw/arm/mps2.c: SYSCLK_FRQ）  */
/* QEMU 要求 16 <= BAUDDIV <= pclk；模型固定 8N1，分频值只影响后端速率    */
#define SYSCLK_HZ 25000000UL
#define UART_BAUD 115200UL
#define UART_BAUDDIV (SYSCLK_HZ / UART_BAUD) /* = 217 */

static void uart_init(void)
{
    UART0_CTRL = UART_CTRL_TX_EN | UART_CTRL_RX_EN;
    UART0_DIV = UART_BAUDDIV;
}

static void uart_putc(char c)
{
    while (UART0_STATE & UART_STATE_TXFULL)
        ;                /* 等发送缓冲腾空（QEMU 几乎立即完成） */
    UART0_DATA = (uint32_t)c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

/* 32 位十六进制打印：只用移位，连 libgcc 的除法例程都不需要 */
static void uart_puthex(uint32_t v)
{
    static const char hex[] = "0123456789abcdef";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

/* ---- 链接脚本导出的布局符号：两段式加载的证据 ---- */
extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss, _etext, _estack;

/* .data 验证：有非零初值，初始值存放在 FLASH，运行时住 RAM */
static uint32_t data_var = 0x20260830UL;
/* .bss 验证：无初值，C 标准要求进入 main 前已被清零 */
static uint32_t bss_var;

int main(void)
{
    uart_init();

    uart_puts("\r\nhello baremetal\r\n");
    uart_puts("text  : FLASH 0x00000000 .. _etext ");
    uart_puthex((uint32_t)&_etext);
    uart_puts("\r\n");
    uart_puts(".data : copy ");
    uart_puthex((uint32_t)&_sidata);
    uart_puts(" (LMA in FLASH) -> ");
    uart_puthex((uint32_t)&_sdata);
    uart_puts(" (VMA in RAM)\r\n");
    uart_puts(".bss  : zero ");
    uart_puthex((uint32_t)&_sbss);
    uart_puts(" .. ");
    uart_puthex((uint32_t)&_ebss);
    uart_puts("\r\n");
    uart_puts("data_var @ ");
    uart_puthex((uint32_t)&data_var);
    uart_puts(" = ");
    uart_puthex(data_var);
    uart_puts(" (reset copy OK)\r\n");
    uart_puts("bss_var  @ ");
    uart_puthex((uint32_t)&bss_var);
    uart_puts(" = ");
    uart_puthex(bss_var);
    uart_puts(" (zero OK)\r\n");
    uart_puts("stack  : MSP top ");
    uart_puthex((uint32_t)&_estack);
    uart_puts("\r\n");

    for (;;)
        __asm volatile ("wfi"); /* 功耗友好地停机；中断可唤醒 */
}
