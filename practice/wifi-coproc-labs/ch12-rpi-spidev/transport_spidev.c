/* transport_spidev.c —— 真树莓派传输层（ch12 §12.1–12.2，Linux 目标）
 *
 * 三件事：打开 /dev/spidev0.0、三个 ioctl（mode0/速度/交换）、DRDY 用
 * sysfs 轮询（零依赖骨架；真机部署建议换 libgpiod 边沿事件——正文 12.2）。
 * 验证形态（SPEC §2）：zig cc -target x86_64-linux 交叉编译入库，真机待板。
 * DRDY sysfs 使能：echo 17 > /sys/class/gpio/export; echo in > direction
 */
#include "transport.h"
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/spi/spidev.h>

#ifndef DRDY_GPIO
#define DRDY_GPIO 17 /* ch11 §11.3 的合同脚；sysfs legacy 路线 */
#endif

static int s_spi = -1, s_gpio = -1;
static uint32_t s_speed = 1000000;

static char *drdy_path(void)
{
    static char p[64];
    snprintf(p, sizeof p, "/sys/class/gpio/gpio%d/value", DRDY_GPIO);
    return p;
}

int spidev_open(const char *dev, uint32_t speed_hz)
{
    s_speed = speed_hz;
    s_spi = open(dev ? dev : "/dev/spidev0.0", O_RDWR);
    if (s_spi < 0) {
        perror("open spidev（dtparam=spi=on 了吗？）");
        return -1;
    }
    uint8_t mode = SPI_MODE_0; /* 与 ch02 §2.1 对表：Mode0 */
    uint8_t bits = 8;
    ioctl(s_spi, SPI_IOC_WR_MODE, &mode);
    ioctl(s_spi, SPI_IOC_WR_BITS_PER_WORD, &bits);
    ioctl(s_spi, SPI_IOC_WR_MAX_SPEED_HZ, &s_speed);

    s_gpio = open(drdy_path(), O_RDONLY);
    if (s_gpio < 0)
        perror("open drdy sysfs（export 了吗？）——降级为定时轮询");
    return 0;
}

static int spidev_xfer(uint8_t *tx, uint8_t *rx, size_t n)
{
    struct spi_ioc_transfer t;
    memset(&t, 0, sizeof t);
    t.tx_buf = (unsigned long)tx; /* 一次 ioctl 双向搬运（ch12 §12.1 ③） */
    t.rx_buf = (unsigned long)rx;
    t.len = n;
    t.speed_hz = s_speed;
    t.bits_per_word = 8;
    return ioctl(s_spi, SPI_IOC_MESSAGE(1), &t) < 0 ? -1 : 0;
}

static int spidev_drdy(void)
{
    if (s_gpio < 0)
        return 0; /* 降级：靠主循环定时交换兜底（正文 12.3 的定时源） */
    char v = '0';
    if (lseek(s_gpio, 0, SEEK_SET) < 0)
        return 0;
    if (read(s_gpio, &v, 1) == 1)
        return v == '1';
    return 0;
}

struct transport *transport_spidev(void)
{
    static struct transport t = { "spidev", spidev_xfer, spidev_drdy };
    return &t;
}
