/* idf_stub.h —— IDF 桩头：让 S3 骨架在本机过编译（API 形状 + 任务逻辑）
 * 真机编译时删除 include 路径即回到真 <driver/spi_slave.h> 与 FreeRTOS。
 * 桩只提供类型与函数原型签名，不做任何事——它是"编译期形状检查"，不是仿真。 */
#ifndef IDF_STUB_H
#define IDF_STUB_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* ---- FreeRTOS 桩 ---- */
typedef void *QueueHandle_t;
typedef uint32_t TickType_t;
#define pdTRUE 1
#define pdFALSE 0
#define portMAX_DELAY 0xFFFFFFFFu
QueueHandle_t xQueueCreate(int len, uint32_t sz);
int xQueueSend(QueueHandle_t q, const void *item, TickType_t wait);
int xQueueReceive(QueueHandle_t q, void *out, TickType_t wait);
int xQueuePeek(QueueHandle_t q, void *out, TickType_t wait);
int uxQueueMessagesWaiting(QueueHandle_t q);
typedef void (*TaskFunc)(void *);
int xTaskCreate(TaskFunc fn, const char *name, uint32_t stack, void *arg, int prio,
                 void **handle);
void gpio_reset_pin(int pin);
int gpio_set_direction(int pin, int mode);
int gpio_set_level(int pin, int level);
#define GPIO_MODE_OUTPUT 1

/* ---- spi_slave 桩 ---- */
#define SPI2_HOST 1
#define SPI_DMA_CH_AUTO 3
#define WORD_ALIGNED_ATTR __attribute__((aligned(4)))
typedef struct {
    int mosi_io_num, miso_io_num, sclk_io_num;
} spi_bus_config_t;
typedef struct spi_slave_transaction {
    size_t length;
    const void *tx_buffer;
    void *rx_buffer;
} spi_slave_transaction_t;
typedef struct {
    int mode;
    int queue_size;
    void (*post_setup_cb)(spi_slave_transaction_t *);
} spi_slave_interface_config_t;
int spi_slave_initialize(int host, const spi_bus_config_t *b,
                         const spi_slave_interface_config_t *s, int dma);
int spi_slave_queue_trans(int host, spi_slave_transaction_t *t, TickType_t wait);
int spi_slave_get_trans_result(int host, spi_slave_transaction_t **out, TickType_t wait);

#endif
