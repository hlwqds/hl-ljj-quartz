/* transport.h —— 传输层接口（ch12）：宿主主循环唯一依赖的"动词"
 *
 * 把 ch02 的两个动作抽象成接口：一次全双工交换 + DRDY 就绪探测。
 * 两个实现：transport_spidev.c（真 Linux，/dev/spidev + sysfs DRDY）、
 * transport_fake.c（内存对端 echo 从机，Windows 可跑全链）。
 * 协议层（cobs/crc32/framing/control）在本层之上，一行不改。
 */
#ifndef TRANSPORT_H
#define TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

#define TR_XCHG 512 /* 与 ch02 §2.2 同一份合同：一次交换固定 512B */

struct transport {
    const char *name;
    /* 全双工交换：tx 发出（无内容填 IDLE 0x00），rx 收回对端挂的缓冲 */
    int (*xfer)(uint8_t *tx, uint8_t *rx, size_t n);
    /* DRDY 非阻塞探测：对端有待发数据返回 1 */
    int (*drdy)(void);
};

#endif
