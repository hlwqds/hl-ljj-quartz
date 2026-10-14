/* spi_slave_task.c —— S3（Korvo-1）侧 SPI 从机任务骨架（系列 ch02 §2.4）
 *
 * 形态对齐 ESP-IDF 的 spi_slave 驱动：队列挂缓冲等主机来时钟；post 回调里
 * 维护 DRDY 电平（有货拉高、清空拉低——ch02 §2.3 时序图的 S3 半边）。
 * 验证方式（SPEC §2）：对 stub/ 下的桩 IDF 头在本机编译——API 形状与任务
 * 逻辑过编译器，真机编译刷机待板。
 *
 * 引脚按 ch01/04 审计结论填（示例占位：FSPI 四脚 + GPIO 挑的 DRDY——
 * 上板前按 Korvo-1 原理图的空闲脚租约表替换）。
 */
#include "idf_stub.h" /* 真机换成 <driver/spi_slave.h> + "freertos/FreeRTOS.h" 等 */

#define XCHG_SIZE 512
#define PIN_DRDY 18 /* 占位：审计后的空闲脚 */

static QueueHandle_t s_to_link; /* 应用 → 链路（要发的帧） */
static QueueHandle_t s_from_link; /* 链路 → 应用（收到的交换缓冲） */

static void drdy_set(int high)
{
    gpio_set_level(PIN_DRDY, high);
}

/* 事务前后回调：DMA 挂好缓冲后（pre）拉高 DRDY；事务完成（post）按队列状态回落 */
static void post_setup_cb(spi_slave_transaction_t *t)
{
    (void)t;
    int pending = 0;
    xQueuePeek(s_to_link, NULL, 0) != pdFALSE ? (pending = 1) : (pending = uxQueueMessagesWaiting(s_to_link) > 0);
    drdy_set(pending);
}

void spi_slave_task(void *arg)
{
    (void)arg;
    spi_bus_config_t buscfg = { 0 };
    /* 真机版填 mosi/miso/sclk 的审计引脚号（GPIO 矩阵映射） */
    spi_slave_interface_config_t slvcfg = { 0 };
    slvcfg.mode = 0;            /* Mode0：与 F429 对表（ch02 §2.1） */
    slvcfg.queue_size = 4;      /* 队列深度：在途交换上限 */
    slvcfg.post_setup_cb = post_setup_cb;
    spi_slave_initialize(SPI2_HOST, &buscfg, &slvcfg, SPI_DMA_CH_AUTO);

    gpio_reset_pin(PIN_DRDY);
    gpio_set_direction(PIN_DRDY, GPIO_MODE_OUTPUT);
    drdy_set(0);

    static WORD_ALIGNED_ATTR uint8_t rxbuf[XCHG_SIZE];
    static WORD_ALIGNED_ATTR uint8_t txbuf[XCHG_SIZE];
    spi_slave_transaction_t t = { 0 };
    t.rx_buffer = rxbuf;
    t.tx_buffer = txbuf;

    for (;;) {
        /* 准备 TX 缓冲：队列有帧则填入，否则 IDLE 填充 0（帧层合法空闲） */
        memset(txbuf, 0, XCHG_SIZE);
        uint32_t len = 0;
        if (xQueueReceive(s_to_link, &len, 0) == pdTRUE && len <= XCHG_SIZE) {
            /* 真机版：帧数据拷入 txbuf（演示骨架仅记账长度） */
            drdy_set(1);
        }
        t.length = XCHG_SIZE * 8; /* bit 计数，IDF 惯例 */

        spi_slave_queue_trans(SPI2_HOST, &t, portMAX_DELAY);
        spi_slave_transaction_t *done;
        spi_slave_get_trans_result(SPI2_HOST, &done, portMAX_DELAY); /* 等主机时钟完成
            （桩编译首版就在这里抓到指针层级错误：真 API 出参是 **，不是 *——
             这正是桩头"API 形状检查"的价值，run.log 排错记） */

        /* 收到的字节交给应用侧（真机版接 ch03 帧层 fr_feed） */
        xQueueSend(s_from_link, rxbuf, 0);
        int more = uxQueueMessagesWaiting(s_to_link) > 0;
        drdy_set(more); /* 有货保持高，清空回落低 */
    }
}

void app_main(void)
{
    s_to_link = xQueueCreate(8, sizeof(uint32_t));
    s_from_link = xQueueCreate(8, XCHG_SIZE);
    xTaskCreate(spi_slave_task, "spi_slave", 4096, NULL, 5, NULL);
}
