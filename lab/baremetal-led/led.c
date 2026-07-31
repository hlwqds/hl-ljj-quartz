/*
 * led.c — 无 OS 的 LED 驱动（裸机）
 *
 * 在 vexpress-a9 上点亮/熄灭主板 LED，同时通过串口打印状态。
 * 这就是"设备驱动"在没有操作系统时的样子：直接读写硬件寄存器。
 */

/* vexpress-a9 关键 MMIO 地址 */
#define SYS_LED     0x10000008   /* 主板 LED 寄存器（8 个 LED） */
#define UART0_DR    0x10009000   /* PL011 UART 数据寄存器 */
#define UART0_FR    0x10009018   /* PL011 UART 状态寄存器 */

/* 指向硬件寄存器的 volatile 指针 */
#define REG(addr) (*(volatile unsigned int *)(addr))

/* 简单延时（忙等循环） */
static void delay(unsigned int count)
{
    while (count--) {
        asm volatile("nop");
    }
}

/* 串口输出单个字符 */
static void uart_putc(char c)
{
    /* 等待 UART 发送缓冲区空闲（FR bit3 = BUSY） */
    while (REG(UART0_FR) & (1 << 3))
        ;
    REG(UART0_DR) = c;
}

/* 串口输出字符串 */
static void uart_puts(const char *s)
{
    while (*s) {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s++);
    }
}

/* 主函数：LED 闪烁 */
void main(void)
{
    uart_puts("\n=== Bare-metal LED Driver (no OS) ===\n");
    uart_puts("Writing to SYS_LED @ 0x10000008\n\n");

    unsigned int led_state = 0;

    /* 闪烁 5 次，每次同时串口打印状态 */
    for (int i = 0; i < 5; i++) {
        /* 点亮 LED0（最低位） */
        led_state |= 0x01;
        REG(SYS_LED) = led_state;
        uart_puts("LED ON  (reg write 0x01)\n");

        delay(5000000);

        /* 熄灭 LED0 */
        led_state &= ~0x01;
        REG(SYS_LED) = led_state;
        uart_puts("LED OFF (reg write 0x00)\n");

        delay(5000000);
    }

    uart_puts("\n=== LED blink done, reading back SYS_LED ===\n");

    /* 读回 LED 寄存器，验证写入真实生效 */
    unsigned int val = REG(SYS_LED);
    uart_puts("SYS_LED readback = 0x");
    /* 简单输出十六进制 */
    char hex[] = "0123456789abcdef";
    uart_putc(hex[(val >> 4) & 0xf]);
    uart_putc(hex[val & 0xf]);
    uart_puts("\n");

    uart_puts("=== DONE ===\n");
}
