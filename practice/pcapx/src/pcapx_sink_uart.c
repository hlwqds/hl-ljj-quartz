/*
 * pcapx_sink_uart.c —— UART 帧协议流 sink（宿主串口收集重组 pcap）
 *
 * 规格：docs/spec/pcapx.md；冻结接口：include/pcapx.h
 *
 * == 帧协议（宿主 tools/pcapx_uart_collect.py 按此对齐） ==
 *   帧 := "PCAX"                      4 字节魔数（ASCII，抗日志穿插）
 *         + uint16_le frame_len       帧载荷长度（1..512）
 *         + payload[frame_len]        pcap 字节流片段
 *         + uint16_le crc16           CRC-16/CCITT-FALSE(payload)
 *             多项式 0x1021、初值 0xFFFF、不反射、不异或输出
 *             （检验向量：crc16("123456789") == 0x29B1）
 *   所有多字节整数小端（Xtensa 本机序）。
 *   语义：这是纯传输封装。pcapx core 的 sink write 是无边界字节流
 *   （24B 全局头 + 若干记录），本 sink 把它按 512 字节切片装帧；
 *   宿主侧校验 CRC 后把各帧 payload 顺序拼接即为完整 pcap 文件。
 *   宿主重同步：魔数命中但 len>512 或 CRC 失败 → 向后跳 1 字节继续
 *   扫描（帧间/帧内混入的日志文本靠这一步滤掉）。
 *
 * == 丢弃语义（统计口径） ==
 *   uart_write_bytes 失败（驱动被删/参数错，带 TX 环形缓冲的正常阻塞
 *   不会失败）时：该帧整体丢弃，frames_dropped++，进入 broken 状态。
 *   broken 之后所有后续数据只计数不发送（bytes_dropped++）——帧载荷是
 *   pcap 字节流的连续片段，丢中间一帧后继续发只会让宿主重组出静默
 *   损坏的文件；断流后宿主拿到的 pcap 前缀仍然合法，由 validate 脚本
 *   报告文件截断。首次失败的 write 返回 ESP_FAIL（core 可观测），
 *   后续返回 ESP_OK 但只在 close 日志里结算，避免错误刷屏。
 *
 * == UART 占用（真机须知） ==
 *   - UART0 是 ROM/console 默认口：构造器允许指定 uart_num；驱动已装
 *     （esp_console/uart VFS 先装了）时复用不重装、也不改波特率——
 *     帧与 console 文本在 TX 环内按「整次 uart_write_bytes 调用」原子
 *     交错（esp_driver_uart/src/uart.c uart_tx_all 持 tx_mux），宿主靠
 *     魔数+CRC 提帧。
 *   - esp32 上 UART1 的 IO_MUX 默认脚 GPIO10(TX)/GPIO9(RX) 在 flash
 *     总线上（soc/esp32/include/soc/uart_pins.h），真机用 UART1 前必须
 *     uart_set_pin() 改到实际接线；UART2 默认 GPIO17(TX)/GPIO16(RX)
 *     空闲可用。带 USB 的模组建议直接用 USB-Serial-JTAG CDC（不占
 *     UART 外设，esp_console 有对应 REPL 后端）。
 *   - QEMU 只把 UART0 接到宿主控制台；UART1/2 的 TX 在本仓库 QEMU
 *     环境不保证可见——QEMU lab 请用 semihost/RAM sink，UART sink 面向
 *     真机（或 UART0 混流模式从 run.log 提帧）。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "driver/uart.h"
#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"

#include "pcapx.h"

#define TAG "pcapx"

#define UART_FRAME_MAGIC "PCAX"
#define UART_FRAME_MAGIC_LEN 4
#define UART_FRAME_MAX 512                            /* 单帧最大载荷 */
#define UART_FRAME_OVERHEAD (UART_FRAME_MAGIC_LEN + 2 + 2)
#define UART_TX_RING 4096                             /* 驱动 TX 环形缓冲 */
#define UART_RX_BUF 256                               /* 本 sink 不收，最小合法值 */
#define UART_DEFAULT_BAUD 115200

/* CRC-16/CCITT-FALSE 查表（表由多项式 0x1021、MSB 先行生成，脚本核验
 * 过检验向量 "123456789" -> 0x29B1；运行时零外部依赖） */
static const uint16_t s_crc16_table[256] = {
    0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50A5, 0x60C6, 0x70E7,
    0x8108, 0x9129, 0xA14A, 0xB16B, 0xC18C, 0xD1AD, 0xE1CE, 0xF1EF,
    0x1231, 0x0210, 0x3273, 0x2252, 0x52B5, 0x4294, 0x72F7, 0x62D6,
    0x9339, 0x8318, 0xB37B, 0xA35A, 0xD3BD, 0xC39C, 0xF3FF, 0xE3DE,
    0x2462, 0x3443, 0x0420, 0x1401, 0x64E6, 0x74C7, 0x44A4, 0x5485,
    0xA56A, 0xB54B, 0x8528, 0x9509, 0xE5EE, 0xF5CF, 0xC5AC, 0xD58D,
    0x3653, 0x2672, 0x1611, 0x0630, 0x76D7, 0x66F6, 0x5695, 0x46B4,
    0xB75B, 0xA77A, 0x9719, 0x8738, 0xF7DF, 0xE7FE, 0xD79D, 0xC7BC,
    0x48C4, 0x58E5, 0x6886, 0x78A7, 0x0840, 0x1861, 0x2802, 0x3823,
    0xC9CC, 0xD9ED, 0xE98E, 0xF9AF, 0x8948, 0x9969, 0xA90A, 0xB92B,
    0x5AF5, 0x4AD4, 0x7AB7, 0x6A96, 0x1A71, 0x0A50, 0x3A33, 0x2A12,
    0xDBFD, 0xCBDC, 0xFBBF, 0xEB9E, 0x9B79, 0x8B58, 0xBB3B, 0xAB1A,
    0x6CA6, 0x7C87, 0x4CE4, 0x5CC5, 0x2C22, 0x3C03, 0x0C60, 0x1C41,
    0xEDAE, 0xFD8F, 0xCDEC, 0xDDCD, 0xAD2A, 0xBD0B, 0x8D68, 0x9D49,
    0x7E97, 0x6EB6, 0x5ED5, 0x4EF4, 0x3E13, 0x2E32, 0x1E51, 0x0E70,
    0xFF9F, 0xEFBE, 0xDFDD, 0xCFFC, 0xBF1B, 0xAF3A, 0x9F59, 0x8F78,
    0x9188, 0x81A9, 0xB1CA, 0xA1EB, 0xD10C, 0xC12D, 0xF14E, 0xE16F,
    0x1080, 0x00A1, 0x30C2, 0x20E3, 0x5004, 0x4025, 0x7046, 0x6067,
    0x83B9, 0x9398, 0xA3FB, 0xB3DA, 0xC33D, 0xD31C, 0xE37F, 0xF35E,
    0x02B1, 0x1290, 0x22F3, 0x32D2, 0x4235, 0x5214, 0x6277, 0x7256,
    0xB5EA, 0xA5CB, 0x95A8, 0x8589, 0xF56E, 0xE54F, 0xD52C, 0xC50D,
    0x34E2, 0x24C3, 0x14A0, 0x0481, 0x7466, 0x6447, 0x5424, 0x4405,
    0xA7DB, 0xB7FA, 0x8799, 0x97B8, 0xE75F, 0xF77E, 0xC71D, 0xD73C,
    0x26D3, 0x36F2, 0x0691, 0x16B0, 0x6657, 0x7676, 0x4615, 0x5634,
    0xD94C, 0xC96D, 0xF90E, 0xE92F, 0x99C8, 0x89E9, 0xB98A, 0xA9AB,
    0x5844, 0x4865, 0x7806, 0x6827, 0x18C0, 0x08E1, 0x3882, 0x28A3,
    0xCB7D, 0xDB5C, 0xEB3F, 0xFB1E, 0x8BF9, 0x9BD8, 0xABBB, 0xBB9A,
    0x4A75, 0x5A54, 0x6A37, 0x7A16, 0x0AF1, 0x1AD0, 0x2AB3, 0x3A92,
    0xFD2E, 0xED0F, 0xDD6C, 0xCD4D, 0xBDAA, 0xAD8B, 0x9DE8, 0x8DC9,
    0x7C26, 0x6C07, 0x5C64, 0x4C45, 0x3CA2, 0x2C83, 0x1CE0, 0x0CC1,
    0xEF1F, 0xFF3E, 0xCF5D, 0xDF7C, 0xAF9B, 0xBFBA, 0x8FD9, 0x9FF8,
    0x6E17, 0x7E36, 0x4E55, 0x5E74, 0x2E93, 0x3EB2, 0x0ED1, 0x1EF0,
};

static uint16_t crc16_ccitt_false(const uint8_t *data, size_t len)
{
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        crc = (uint16_t)((crc << 8) ^ s_crc16_table[((crc >> 8) ^ data[i]) & 0xFF]);
    }
    return crc;
}

typedef struct {
    pcapx_sink_t base; /* 必须是首成员 */
    char name_buf[32]; /* "uart1@921600" */
    int uart_num;
    int baud;
    bool opened;
    bool installed_by_me; /* 本 sink 执行了 uart_driver_install 才在 close 删除 */
    bool broken;

    uint8_t stage[UART_FRAME_MAX];
    size_t stage_len;

    uint32_t frames_sent, frames_dropped, bytes_staged, bytes_dropped;
} uart_sink_t;

/* 组帧并单次 uart_write_bytes 发出（驱动层 tx_mux 保证整帧原子，
 * 不会与 console 文本按字节交错） */
static esp_err_t uart_emit(uart_sink_t *me, const uint8_t *payload, size_t len)
{
    uint8_t frame[UART_FRAME_OVERHEAD + UART_FRAME_MAX];
    memcpy(frame, UART_FRAME_MAGIC, UART_FRAME_MAGIC_LEN);
    frame[4] = (uint8_t)(len & 0xFF);
    frame[5] = (uint8_t)(len >> 8);
    memcpy(frame + UART_FRAME_MAGIC_LEN + 2, payload, len);
    uint16_t crc = crc16_ccitt_false(payload, len);
    size_t flen = UART_FRAME_MAGIC_LEN + 2 + len;
    frame[flen] = (uint8_t)(crc & 0xFF);
    frame[flen + 1] = (uint8_t)(crc >> 8);
    flen += 2;

    int w = uart_write_bytes(me->uart_num, frame, flen);
    if (w != (int)flen) {
        me->frames_dropped++;
        me->broken = true;
        ESP_LOGE(TAG, "SINK_TX_FAIL uart=%d want=%u got=%d frame dropped", me->uart_num,
                 (unsigned)flen, w);
        return ESP_FAIL;
    }
    me->frames_sent++;
    return ESP_OK;
}

static esp_err_t uart_sink_open(pcapx_sink_t *s)
{
    uart_sink_t *me = (uart_sink_t *)s;
    if (me->opened) {
        return ESP_ERR_INVALID_STATE;
    }
    if (me->uart_num < 0 || me->uart_num >= UART_NUM_MAX || me->baud <= 0) {
        ESP_LOGE(TAG, "SINK_OPEN_FAIL uart=%d baud=%d hint='检查 uart_num(0..%d) 与波特率'",
                 me->uart_num, me->baud, (int)(UART_NUM_MAX - 1));
        return ESP_ERR_INVALID_ARG;
    }

    me->broken = false;
    me->stage_len = 0;
    me->frames_sent = 0;
    me->frames_dropped = 0;
    me->bytes_staged = 0;
    me->bytes_dropped = 0;

    if (uart_is_driver_installed(me->uart_num)) {
        /* 典型：UART0 已被 console/VFS 装上。复用，不动波特率/引脚 */
        ESP_LOGI(TAG, "uart%d driver already installed, reuse (baud/pins unchanged)",
                 me->uart_num);
    } else {
        /* IDF v6 签名：uart_param_config(uart_num, const uart_config_t*)
         * （esp_driver_uart/include/driver/uart.h:494，v5 的多参数形式已改） */
        uart_config_t cfg = {
            .baud_rate = me->baud,
            .data_bits = UART_DATA_8_BITS,
            .parity = UART_PARITY_DISABLE,
            .stop_bits = UART_STOP_BITS_1,
            .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
            .source_clk = UART_SCLK_DEFAULT,
        };
        esp_err_t err = uart_param_config(me->uart_num, &cfg);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "SINK_OPEN_FAIL uart=%d step=param err=%s", me->uart_num,
                     esp_err_to_name(err));
            return err;
        }
        err = uart_driver_install(me->uart_num, UART_RX_BUF, UART_TX_RING, 0, NULL, 0);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "SINK_OPEN_FAIL uart=%d step=driver_install err=%s", me->uart_num,
                     esp_err_to_name(err));
            return err;
        }
        me->installed_by_me = true;
    }

    me->opened = true;
    ESP_LOGI(TAG, "SINK_OPEN sink=uart num=%d baud=%d frame_max=%u", me->uart_num, me->baud,
             (unsigned)UART_FRAME_MAX);
    return ESP_OK;
}

static esp_err_t uart_sink_write(pcapx_sink_t *s, const void *buf, size_t len)
{
    uart_sink_t *me = (uart_sink_t *)s;
    if (!me->opened) {
        return ESP_ERR_INVALID_STATE;
    }
    if (me->broken) {
        /* 见文件头丢弃语义：断流后只计数，避免错误刷屏 */
        me->bytes_dropped += (uint32_t)len;
        return ESP_OK;
    }

    const uint8_t *p = buf;
    size_t n = len;
    esp_err_t ret = ESP_OK;
    while (n > 0) {
        size_t room = UART_FRAME_MAX - me->stage_len;
        size_t take = n < room ? n : room;
        memcpy(me->stage + me->stage_len, p, take);
        me->stage_len += take;
        me->bytes_staged += (uint32_t)take;
        p += take;
        n -= take;
        if (me->stage_len == UART_FRAME_MAX) {
            ret = uart_emit(me, me->stage, me->stage_len);
            me->stage_len = 0;
            if (ret != ESP_OK) {
                me->bytes_dropped += (uint32_t)n;
                return ret; /* 首次失败上抛，core 可观测 */
            }
        }
    }
    return ESP_OK;
}

static esp_err_t uart_sink_close(pcapx_sink_t *s)
{
    uart_sink_t *me = (uart_sink_t *)s;
    if (!me->opened) {
        return ESP_OK; /* open 失败后仍被调 close 的幂等处理 */
    }
    /* 冲出不足 512B 的尾部残帧（宿主拼接需要完整的字节流尾巴） */
    if (me->stage_len > 0 && !me->broken) {
        uart_emit(me, me->stage, me->stage_len);
        me->stage_len = 0;
    }
    if (me->installed_by_me) {
        /* 等 TX 环清空再删驱动，否则残帧直接蒸发 */
        uart_wait_tx_done(me->uart_num, pdMS_TO_TICKS(1000));
        uart_driver_delete(me->uart_num);
        me->installed_by_me = false;
    }
    me->opened = false;
    ESP_LOGI(TAG, "SINK_CLOSE sink=uart num=%d frames=%u dropped=%u bytes_in=%u bytes_dropped=%u",
             me->uart_num, (unsigned)me->frames_sent, (unsigned)me->frames_dropped,
             (unsigned)me->bytes_staged, (unsigned)me->bytes_dropped);
    return ESP_OK;
}

static void uart_sink_free(pcapx_sink_t *s)
{
    free(s); /* 单块分配（含 name/stage），见构造器 */
}

pcapx_sink_t *pcapx_sink_uart_new(int uart_num, int baud)
{
    uart_sink_t *me = calloc(1, sizeof(*me));
    if (me == NULL) {
        return NULL;
    }
    me->uart_num = uart_num;
    me->baud = baud > 0 ? baud : UART_DEFAULT_BAUD;
    snprintf(me->name_buf, sizeof(me->name_buf), "uart%d@%d", me->uart_num, me->baud);

    me->base.name = me->name_buf;
    me->base.open = uart_sink_open;
    me->base.write = uart_sink_write;
    me->base.close = uart_sink_close;
    me->base.free_fn = uart_sink_free;
    return &me->base;
}
