/*
 * f407_gpio.c -- STM32F407 真寄存器点灯/读键/复用预演（编译验证目标）
 *
 * 目标：STM32F407VET6（Cortex-M4F），-mcpu=cortex-m4 交叉编译。
 * QEMU 没有 F407 机型：本文件在本章的验证层次是
 *   1. arm-none-eabi-gcc 编译链接通过（真机内存映射 f407.ld）
 *   2. arm-none-eabi-objdump 反汇编中 GPIOA/RCC 地址可见（文章摘录）
 * 真寄存器地址/位定义依据 ST RM0090：
 *   - RCC 基址 0x40023800（§5.3 RCC 寄存器）
 *     RCC_AHB1ENR 偏移 0x30：GPIOAEN=bit0（GPIO 时钟在 AHB1 上——F4 特色）
 *   - GPIOA 基址 0x40020000（§8.4 GPIO 寄存器）：
 *     MODER +0x00  OTYPER +0x04  OSPEEDR +0x08  PUPDR +0x0C
 *     IDR    +0x10  ODR    +0x14  BSRR    +0x18  LCKR  +0x1C
 *     AFRL   +0x20  AFRH   +0x24（AFR[0]/AFR[1]，复用功能路由表）
 */

#include <stdint.h>

/* ------------------------------------------------------------------ */
/* 写法一：CMSIS 风格——结构体映射寄存器（与官方 stm32f4xx.h 同构，      */
/* 但零依赖自写。C 指针算术天然表达"寄存器 = 基址 + 偏移"）             */
/* ------------------------------------------------------------------ */

typedef struct {
    volatile uint32_t MODER;   /* +0x00 模式：2bit/引脚 00输入 01输出 10复用 11模拟 */
    volatile uint32_t OTYPER;  /* +0x04 输出类型：1bit/引脚 0推挽 1开漏             */
    volatile uint32_t OSPEEDR; /* +0x08 输出速度：2bit/引脚 00低 01中 10高 11极高   */
    volatile uint32_t PUPDR;   /* +0x0C 上拉/下拉：2bit/引脚 00无 01上拉 10下拉     */
    volatile uint32_t IDR;     /* +0x10 输入数据（只读，1bit/引脚）                 */
    volatile uint32_t ODR;     /* +0x14 输出数据                                    */
    volatile uint32_t BSRR;    /* +0x18 位设置/复位：低16位=置1，高16位=清0         */
    volatile uint32_t LCKR;    /* +0x1C 配置锁定                                    */
    volatile uint32_t AFR[2];  /* +0x20/+0x24 复用功能：4bit/引脚，AFRL=引脚0..7     */
    volatile uint32_t BRR;     /* +0x28 仅复位（BSRR 高16位的独立镜像，F4 起有）    */
} GPIO_TypeDef;                /*                    AFRH=引脚8..15                 */

typedef struct {
    volatile uint32_t CR;      /* +0x00 HSI/HSE/PLL 就绪与使能（HSION/HSEON/PLLON） */
    volatile uint32_t PLLCFGR; /* +0x04 PLL 分频/倍频参数（PLLM/PLLN/PLLP/PLLQ）     */
    volatile uint32_t CFGR;    /* +0x08 系统时钟切换/分频（SW/HPRE/PPRE1/PPRE2）    */
    volatile uint32_t _r0;     /* +0x0C 保留                                        */
    volatile uint32_t AHB1RSTR;/* +0x10 AHB1 外设复位                              */
    volatile uint32_t AHB2RSTR;/* +0x14                                             */
    volatile uint32_t AHB3RSTR;/* +0x18                                             */
    volatile uint32_t _r1;     /* +0x1C 保留                                        */
    volatile uint32_t APB1RSTR;/* +0x20                                             */
    volatile uint32_t APB2RSTR;/* +0x24                                             */
    /* 0x28 与 0x2C 是两个连续保留字——少写一个，AHB1ENR 就会错位到 0x2C
     * （本章反汇编实证过这个 bug，见文章 5.3 节；CMSIS 头里 RESERVED2/RESERVED3
     *  双保留不是装饰）*/
    volatile uint32_t _r2;     /* +0x28 保留                                        */
    volatile uint32_t _r3;     /* +0x2C 保留                                        */
    volatile uint32_t AHB1ENR; /* +0x30 AHB1 外设时钟使能：GPIOAEN=bit0..GPIOHEN=bit7 */
} RCC_TypeDef;

#define GPIOA_BASE 0x40020000UL /* RM0090 §2.3：GPIOA 在 AHB1，0x4002_0000 */
#define RCC_BASE   0x40023800UL /* RM0090 §2.3：RCC 基址 0x4002_3800       */

#define GPIOA ((GPIO_TypeDef *)GPIOA_BASE)
#define RCC   ((RCC_TypeDef *)RCC_BASE)

#define RCC_AHB1ENR_GPIOA (1UL << 0) /* GPIOAEN（RM0090 §5.3 AHB1ENR 位定义） */

/* 引脚编号 → MODER/OSPEEDR/PUPDR 的 2bit 掩码与目标值打包 */
#define PIN_MASK_2B(n)  (3UL << ((n) * 2))
#define PIN_VAL_2B(n, v) ((uint32_t)(v) << ((n) * 2))

/* ------------------------------------------------------------------ */
/* 点灯三步（文章 5.3 节主线）：使能时钟 → 配模式 → 写数据              */
/* PA0 = LED（低电平/高电平点亮取决于接线；这里按高电平点亮写）         */
/* ------------------------------------------------------------------ */

static void led_init(void)
{
    /* 第 1 步：开时钟——GPIO 挂在 AHB1 上，置位 RCC_AHB1ENR 的 GPIOAEN */
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOA;

    /* 保守同步：读回一次，确认写真正到达 RCC（写缓冲/流水线延迟的兜底，
     * 也是各厂商例程的通行写法）*/
    (void)RCC->AHB1ENR;

    /* 第 2 步：PA0 配输出。MODER 每引脚 2bit：01 = 通用输出 */
    GPIOA->MODER = (GPIOA->MODER & ~PIN_MASK_2B(0)) | PIN_VAL_2B(0, 1);

    /* 输出细节三件套（都有复位默认值，这里显式写出教学版）*/
    GPIOA->OTYPER &= ~(1UL << 0);          /* 推挽（回收 ch02：万用表测 ≈3.3V 的那种）*/
    GPIOA->OSPEEDR |= PIN_VAL_2B(0, 3);    /* 极高速（LED 场景无所谓，习惯性拉满）*/
    GPIOA->PUPDR &= ~PIN_MASK_2B(0);       /* 无上拉/下拉（推挽输出自己驱动电平）*/
}

/* 第 3 步：写数据——BSRR 单写原子操作（中断安全，5.2 节论证） */
static void led_on(void)
{
    GPIOA->BSRR = 1UL << 0; /* BS0：低 16 位写 1 = ODR0 置 1 */
}

static void led_off(void)
{
    GPIOA->BSRR = 1UL << 16; /* BR0：高 16 位写 1 = ODR0 清 0 */
}

/* 对照组：读-改-写 ODR 翻转——三条指令，中断打断会丢更新（文章论证用） */
static void led_toggle_odr(void)
{
    GPIOA->ODR ^= 1UL << 0;
}

/* ------------------------------------------------------------------ */
/* 输入与上拉：PA1 = 按键（外部按键一端接 PA1、一端接 GND）             */
/* 内部上拉后，空闲读到 1，按下读到 0——"低有效"是按键电路的常态         */
/* ------------------------------------------------------------------ */

static void button_init(void)
{
    /* 时钟已在 led_init() 打开（同一个 GPIOA）*/
    GPIOA->MODER &= ~PIN_MASK_2B(1);                     /* 00 = 输入 */
    GPIOA->PUPDR = (GPIOA->PUPDR & ~PIN_MASK_2B(1)) | PIN_VAL_2B(1, 1); /* 01 = 上拉 */
}

static int button_pressed(void)
{
    return (GPIOA->IDR & (1UL << 1)) == 0; /* 读 IDR，低电平 = 按下 */
}

/* ------------------------------------------------------------------ */
/* AFR + 复用预演：PA2=USART2_TX、PA3=USART2_RX（AF7，RM0090 AF 映射表）*/
/* 这是 ch06 UART 实战的引脚侧前置——CPU 写 ODR 驱动不了复用外设，      */
/* 引脚必须交给外设：MODER=10 + AFR=7，两步完成"路由"                  */
/* ------------------------------------------------------------------ */

static void uart2_pins_init(void)
{
    GPIOA->MODER = (GPIOA->MODER & ~(PIN_MASK_2B(2) | PIN_MASK_2B(3)))   /* PA2/PA3 = 10 复用 */
                   | PIN_VAL_2B(2, 2) | PIN_VAL_2B(3, 2);
    GPIOA->AFR[0] = (GPIOA->AFR[0] & ~((0xFUL << (2 * 4)) | (0xFUL << (3 * 4)))) /* 4bit/引脚清零 */
                    | (7UL << (2 * 4)) | (7UL << (3 * 4));               /* AF7 = USART2 */
    GPIOA->OSPEEDR |= PIN_VAL_2B(2, 3) | PIN_VAL_2B(3, 3);               /* 高速 */
}

/* ------------------------------------------------------------------ */
/* 写法二：裸地址风格——不定义结构体，宏即寄存器                        */
/* 与写法一生成的机器码一致（文章用反汇编对照证明），选哪种是口味问题  */
/* ------------------------------------------------------------------ */

#define GPIOA_MODER (*(volatile uint32_t *)(GPIOA_BASE + 0x00))
#define GPIOA_BSRR  (*(volatile uint32_t *)(GPIOA_BASE + 0x18))
#define RCC_AHB1ENR (*(volatile uint32_t *)(RCC_BASE + 0x30))

static void led_init_addr(void)
{
    RCC_AHB1ENR |= 1UL << 0;                                    /* GPIOAEN */
    (void)RCC_AHB1ENR;                                          /* 读回同步 */
    GPIOA_MODER = (GPIOA_MODER & ~3UL) | 1UL;                   /* PA0 输出 */
}

static void led_on_addr(void)
{
    GPIOA_BSRR = 1UL << 0; /* 与 led_on() 等价 */
}

/* ------------------------------------------------------------------ */
/* main：不依赖任何板级现象也能编译通过的演示序列                       */
/* （QEMU 跑不了本文件——它是 F407 真寄存器；QEMU 侧等价逻辑见 qemu_main.c）
 */
/* ------------------------------------------------------------------ */

static void delay_loops(volatile uint32_t n)
{
    while (n--)
        ;
}

int main(void)
{
    led_init();        /* CMSIS 风格三步链路 */
    button_init();
    uart2_pins_init(); /* ch06 伏笔：先把引脚配好 */

    led_init_addr();   /* 裸地址风格对照（覆盖同样的寄存器）*/
    led_on_addr();

    for (;;) {
        if (button_pressed()) {
            led_toggle_odr();          /* 按住：读改写翻转（对照组）*/
            delay_loops(3000000);
        } else {
            led_on();                  /* 空闲：BSRR 点亮 */
            delay_loops(8000000);
            led_off();                 /* BSRR 熄灭 */
            delay_loops(8000000);
        }
    }
}
