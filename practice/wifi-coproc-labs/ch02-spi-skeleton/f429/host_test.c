/* host_test.c —— F429 交换状态机的宿主逻辑用例（-DHOST_TEST 与 spi_master.c 同编）
 * 验证：CS 包裹顺序、DRDY 触发交换、IDLE 填充为 0、事件序列可回放。 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

uint32_t g_fake_regs[64];
static char g_events[1024][32]; /* 一次交换 = 512 条 DR 写 + 6 条控制事件，64 槽装不下 */
static int g_nev;

void host_log_event(const char *tag, uint32_t v)
{
    if (g_nev < 1024)
        snprintf(g_events[g_nev], sizeof g_events[0], "%s=%u", tag, v);
    g_nev++;
}

void spi_master_init(void);
void spi_master_poll(void);
void spi_master_enqueue(const uint8_t *src, size_t n);
void drdy_isr(void);
const struct xchg {
    int state;
    uint32_t n_exchanges, n_drdy_seen;
    uint8_t tx[512], rx[512];
} *spi_master_stats(void);

static int g_pass, g_fail;
#define CHECK(c, n)                                                                            \
    do {                                                                                       \
        if (c)                                                                                 \
            g_pass++, printf("PASS %s\n", n);                                                  \
        else                                                                                   \
            g_fail++, printf("FAIL %s\n", n);                                                  \
    } while (0)

int main(void)
{
    spi_master_init();
    CHECK(g_nev >= 2, "init 写了 CR1/CR2");

    /* 1) 本端有货：enqueue → 立即一次交换，且 CS 先拉高后拉低（BSRR 序列） */
    g_nev = 0;
    uint8_t msg[8] = { 1, 2, 3, 4, 5, 6, 7, 8 };
    spi_master_enqueue(msg, sizeof msg);
    CHECK(spi_master_stats()->n_exchanges == 1, "enqueue 触发一次交换");
    int cs_on = -1, cs_off = -1, first_dr = -1, last_dr = -1;
    for (int i = 0; i < g_nev; i++) {
        if (!strcmp(g_events[i], "GPIO_BSRR=32768"))
            cs_on = i;
        if (!strcmp(g_events[i], "GPIO_BSRR=2147483648")) /* 1u<<31：BSRR 复位半区 */
            cs_off = i;
        if (!strncmp(g_events[i], "SPI_DR=", 7)) {
            if (first_dr < 0)
                first_dr = i;
            last_dr = i;
        }
    }
    CHECK(cs_on >= 0 && cs_off > cs_on && first_dr > cs_on && last_dr < cs_off,
          "CS 包裹整段 512B 写序列");

    /* 2) DRDY 事件 → 下一拍交换（从机可发起路径） */
    g_nev = 0;
    drdy_isr();
    CHECK(spi_master_stats()->n_drdy_seen == 1, "DRDY 计数入账");
    spi_master_poll();
    CHECK(spi_master_stats()->n_exchanges == 2 && g_nev > 0, "DRDY 触发交换（EXTI 路径）");
    CHECK(spi_master_stats()->n_drdy_seen == 0, "DRDY 消费清零");

    /* 3) 无货不空转：无事发生时 poll 不产生交换 */
    g_nev = 0;
    spi_master_poll();
    CHECK(spi_master_stats()->n_exchanges == 2 && g_nev == 0, "空闲 poll 不空转");

    /* 4) IDLE 填充为 0（帧层语义：空闲字节合法） */
    const struct xchg *st = spi_master_stats();
    int zero_tail = 1;
    for (int i = 8; i < 512; i++)
        if (st->tx[i] != 0)
            zero_tail = 0;
    CHECK(zero_tail, "tx 缓冲尾部 IDLE 填充 0x00");

    printf("\n合计：PASS %d / FAIL %d\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
