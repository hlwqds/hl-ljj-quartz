/*
 * led_module.c — Linux 内核模块版 LED 驱动
 *
 * 对比 1.6.1 裸机版的关键演进：
 * - 不直接写物理地址：用 ioremap() 映射后才能访问硬件寄存器
 * - 不手写串口驱动：用 printk() 输出日志
 * - 有 init/exit 生命周期：module_init / module_exit
 * - 延时用内核 API：msleep() 替代忙等循环
 *
 * 这是"从裸机到内核"的最小一步——先展示内核 API 替代裸机手工活。
 * 平台驱动 + GPIO 子系统等更规范的做法放到后续章节。
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/delay.h>

/* vexpress-a9 LED 寄存器物理地址（和裸机版同一个地址） */
#define SYS_LED_PHYS  0x10000008

/* 映射后的虚拟地址（内核态不能直接写物理地址，必须先 ioremap） */
static void __iomem *led_reg;

static int __init led_init(void)
{
    printk(KERN_INFO "=== Kernel LED Driver (module) ===\n");

    /* 映射物理地址到内核虚拟地址空间 */
    led_reg = ioremap(SYS_LED_PHYS, 4);
    if (!led_reg) {
        printk(KERN_ERR "failed to ioremap LED register\n");
        return -ENOMEM;
    }

    printk(KERN_INFO "ioremap(0x%08x) -> %p\n", SYS_LED_PHYS, led_reg);
    printk(KERN_INFO "blinking 5 times...\n");

    /* 闪烁 5 次 */
    int i;
    for (i = 0; i < 5; i++) {
        iowrite32(0x01, led_reg);
        printk(KERN_INFO "LED ON  (iteration %d)\n", i);
        msleep(500);

        iowrite32(0x00, led_reg);
        printk(KERN_INFO "LED OFF (iteration %d)\n", i);
        msleep(500);
    }

    /* 读回观察（注意：可能受内核其他驱动并发写入影响，值不可靠） */
    unsigned int val = ioread32(led_reg);
    printk(KERN_INFO "LED readback = 0x%02x\n", val);

    printk(KERN_INFO "=== Kernel LED Driver done ===\n");
    return 0;
}

static void __exit led_exit(void)
{
    if (led_reg) {
        iowrite32(0x00, led_reg);
        iounmap(led_reg);
    }
    printk(KERN_INFO "Kernel LED Driver removed\n");
}

module_init(led_init);
module_exit(led_exit);

MODULE_AUTHOR("Linux Driver Tutorial");
MODULE_DESCRIPTION("vexpress-a9 LED driver demo (kernel module)");
MODULE_LICENSE("GPL");
