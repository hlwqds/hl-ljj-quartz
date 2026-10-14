/* spi_master.c —— F429 侧 SPI 主机骨架（系列 ch02）
 *
 * 职责与形态对齐 [[f429-lab|F429 实验室]]的裸机风格：寄存器级配置 + 一个
 * "交换状态机"。本文件刻意做成**双目标编译**：
 *   板级：zig cc -target thumb-freestanding-eabihf -mcpu=cortex_m4 -c spi_master.c
 *   宿主：zig cc -DHOST_TEST ... —— 寄存器访问与延时换成桩，交换状态机
 *         的逻辑（CS 包裹、DRDY 消费、填充/数据分派）可在 PC 上跑用例。
 * 真机替换两处即点火：寄存器宏换成真地址、delay 换 DWT/定时器。
 *
 * 引脚按 ch01 审计结论填（本骨架示例用 SPI1 重映射 PB3/4/5 + PA15 片选
 * + PB0 DRDY（EXTI0）——RMII 撞 PA7 的规避方案，上板前按原理图核对）。
 */
#include <stdint.h>
#include <stddef.h>

#define XCHG_SIZE 512 /* ch02 §2.2：一次交换固定 512B，双向成对 */

/* ---- 寄存器名（双目标共用；真机把偏移换成实际外设基址，位段按 RM0090 命名） ---- */
#define SPI_CR1 0x00
#define SPI_CR2 0x04
#define SPI_SR 0x08
#define SPI_DR 0x0C
#define GPIO_BSRR 0x18
#define EXTI_PR 0x14

/* ---- 寄存器访问（HOST_TEST 时换成桩） ---- */

#ifdef HOST_TEST
extern uint32_t g_fake_regs[64]; /* host_test.c 提供并记录写入 */
extern void host_log_event(const char *tag, uint32_t v);
#define WREG(off, v) (g_fake_regs[(off) >> 2] = (uint32_t)(v), host_log_event(#off, (v)))
#define RREG(off) (g_fake_regs[(off) >> 2])
#define DELAY_US(u) host_log_event("DELAY_US", (u))
#else
#define WREG(off, v) (*(volatile uint32_t *)((uintptr_t)(off)) = (uint32_t)(v))
#define RREG(off) (*(volatile uint32_t *)((uintptr_t)(off)))
#define DELAY_US(u) ((void)(u)) /* 真机：DWT 循环或定时器 */
#endif

/* ---- 交换状态机（逻辑与寄存器解耦，HOST_TEST 就测它） ---- */

enum { XST_IDLE, XST_BUSY };

struct xchg {
    int state;
    uint32_t n_exchanges;
    uint32_t n_drdy_seen;
    uint8_t tx[XCHG_SIZE]; /* 没有数据要发时填 IDLE 填充 0x00（帧层认它合法） */
    uint8_t rx[XCHG_SIZE];
};

static struct xchg g_x;

void spi_master_init(void)
{
    /* Mode0/主模式/软件片选/起始时钟低速（BR=/256），DMA 后续在真机版补 */
    WREG(SPI_CR1, (1u << 2) /*MSTR*/ | (7u << 3) /*BR=/256*/ | (1u << 9) /*SSM*/);
    WREG(SPI_CR2, (1u << 1) /*TXDMAEN*/ | (1u << 0) /*RXDMAEN*/);
    g_x.state = XST_IDLE;
}

static void spi_cs(int on) /* 片选必须包住整段事务（ch02 §2.1 坑 1） */
{
    WREG(GPIO_BSRR, on ? (1u << 15) : (1u << (15 + 16)));
}

/* 一次 512B 交换：CS↓ → 512B 全双工（真机走 DMA，骨架走寄存器模型）→ CS↑ */
static void do_exchange(void)
{
    spi_cs(1);
    DELAY_US(2); /* 首字节稳定间隙（ch02 §2.1 坑 2） */
    WREG(SPI_CR1, RREG(SPI_CR1) | (1u << 6) /*SPE 开启*/);
    g_x.state = XST_BUSY;
    for (int i = 0; i < XCHG_SIZE; i++)
        WREG(SPI_DR, g_x.tx[i]); /* 真机：DMA 搬运；宿主桩记录写序列 */
    WREG(SPI_CR1, RREG(SPI_CR1) & ~(1u << 6));
    DELAY_US(1);
    spi_cs(0);
    g_x.state = XST_IDLE;
    g_x.n_exchanges++;
}

/* DRDY 的 EXTI 服务 routine（真机接 EXTI0；宿主由用例直接调） */
void drdy_isr(void)
{
    g_x.n_drdy_seen++;
    WREG(EXTI_PR, 0xFFFF); /* 清挂起位（写 1 清零） */
}

/* 主循环一拍：只看 DRDY——从机"有货"通知路径（ch02 §2.3 的 EXTI 半边） */
void spi_master_poll(void)
{
    if (g_x.n_drdy_seen > 0) {
        g_x.n_drdy_seen = 0;
        do_exchange();
    }
}

/* 帧层入口：本端有货不必等 DRDY——立即交换，顺路带回 S3 待发数据 */
void spi_master_enqueue(const uint8_t *src, size_t n)
{
    for (size_t i = 0; i < (size_t)XCHG_SIZE; i++)
        g_x.tx[i] = i < n ? src[i] : 0x00;
    do_exchange();
}

const struct xchg *spi_master_stats(void)
{
    return &g_x;
}
