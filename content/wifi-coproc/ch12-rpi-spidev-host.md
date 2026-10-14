---
title: "F429 × Korvo-1（十二）：手搓协议上 Linux——spidev 传输层与守护进程"
date: 2026-10-10 12:00:00
description: "续篇主力章：spidev 的字符设备形态与三个关键 ioctl（SPI_IOC_MESSAGE 一次 512B 全双工交换，与 ch02 交换语义完美同构）；DRDY 从 EXTI 中断变成 poll() 事件（libgpiod/sysfs 两条路）；守护进程主循环——poll 三类事件源 → exchange → fr_feed → 分发，与 F429 主循环同构对照；用户态代价账（syscall/拷贝开销与批合并）；bufsiz 4096 的默认值提醒。配套工程协议层零改动上 Linux。"
tags: [wifi, rpi, linux, spidev, daemon, coprocessor, series]
---

> [!info] WiFi 协处理器实战（续篇） 0. [[wifi-coproc|系列索引]] 1. [[ch01-coproc-architecture|第一章]] … 11. [[ch11-rpi-host-arch|第十一章]] 12. **第十二章：手搓协议上 Linux**

# F429 × Korvo-1（十二）：手搓协议上 Linux——spidev 传输层与守护进程

这一章做续篇的核心实验：**ch03/05/06 的协议源文件一行不改，在 RPi4B 上编译成守护进程**。要写的新代码只有传输层（spidev）与主循环（poll 事件泵）。四步走：spidev 的形态与三个 ioctl（12.1）、DRDY 的事件化（12.2）、守护进程主循环（12.3）、用户态的代价账（12.4）。

---

## 12.1 spidev：被字符设备包装的 SPI 主机

`/dev/spidev0.0` 就是 ch02 那台 SPI 主机控制器的用户态门面，控制全走 ioctl：

```c
int fd = open("/dev/spidev0.0", O_RDWR);
uint8_t mode = 0;                            /* ① 模式：Mode0，与 ch02 §2.1 对表 */
ioctl(fd, SPI_IOC_WR_MODE, &mode);
uint32_t speed = 1000000;                    /* ② 时钟：起步 1 MHz，爬坡见 ch08 */
ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed);

/* ③ 交换：一次 ioctl 同时双向搬 N 字节——与 ch02 的"512B 交换"语义完美同构 */
struct spi_ioc_transfer t = { 0 };
t.tx_buf = (unsigned long)txbuf;             /* 发什么（没内容填 IDLE 0x00） */
t.rx_buf = (unsigned long)rxbuf;             /* 同时收什么 */
t.len = 512;
t.speed_hz = speed;
ioctl(fd, SPI_IOC_MESSAGE(1), &t);           /* 返回后 rxbuf 里是对端挂的缓冲 */
```

一个必须先知道的默认值：**spidev 的单笔传输上限 bufsiz 默认 4096**（`/sys/module/spidev/parameters/bufsiz`）——我们的 512B 交换远在安全区，但如果将来加大交换尺寸撞到 4096，得到的不是错误而是 `-EINVAL`/截断行为，排查起来很绕。第二章"交换大小是合同"的条款，在 Linux 侧由模块参数背书。

## 12.2 DRDY：从 EXTI 向量到 poll 事件

F429 上 DRDY 直入 EXTI 中断向量；Linux 用户态的等价物是**把 GPIO 变成可 poll 的 fd**。两条路：

- **libgpiod（推荐，[[rpi-lab|树莓派实验室]]ch03 的主场）**：`gpiod_chip_open` → `gpiod_line_get` → `gpiod_line_request_both_edges_events` → `gpiod_line_event_get_fd`——拿到 fd 后进同一个 `poll()` 循环，边沿到达读掉事件；
- **sysfs legacy（零依赖兜底，实验骨架采用）**：导出 GPIO 后轮询 `/sys/class/gpio/gpio17/value`——代码只有 open/read，教学最小；真机部署换 libgpiod（正文讲清，骨架保依赖为零）。

## 12.3 守护进程主循环：事件泵

把 F429 主循环的"三个事件源"平移到 fd 世界，**结构逐行同构**：

```c
/* hostd.c 主循环骨架（配套工程）——与 ch02 spi_master_poll 对照阅读 */
for (;;) {
    struct pollfd pfds[2] = {
        { .fd = drdy_fd, .events = POLLIN },   /* ① DRDY 事件（EXTI 的化身） */
        { .fd = timer_fd, .events = POLLIN },  /* ② 定时：keepalive/重试 */
    };
    poll(pfds, 2, -1);

    if (pfds[0].revents)                       /* S3 有货 → 交换 */
        do_exchange();
    if (pfds[1].revents || tx_pending())       /* 到点或有积压 → 交换（顺路捎带） */
        do_exchange();
    /* do_exchange() 内部：512B ioctl → fr_feed(两侧解析器) → control/sock 分发 */
}
```

do*exchange 的三拍（ioctl 交换 → 解析喂帧 → 分发命令/数据）在两个宿主上完全一致——**变的只有"交换"这个动词的实现**。ws*\* API 的阻塞语义在 Linux 下换成信号量/条件变量（比 F429 裸机还简单，pthread 现成）。

## 12.4 用户态的代价账

裸寄存器 → ioctl 的差价要认账：每笔 512B 交换多出 **syscall 进出 + 两次缓冲拷贝**（用户↔内核），典型几十 µs 起步；1 MHz 时 512B 线上时间约 4 ms，开销占比尚可，但**时钟爬到 10 MHz 后 syscall 成分就会显形**（线上 410 µs vs 开销几十 µs）。对策与 ch08 同宗：批量合并（攒帧过河摊薄每笔固定开销）、交换尺寸加大（512 → 1024/2048，注意 bufsiz）——或升级路径 C 的内核模块。预期管理：用户态方案在 RPi4B 上的吞吐量级与 F429 相当或略低，**换来的是 strace/poll/日志这套 Linux 观测全家桶**——调试效率是另一维度的收益。

> [!tip] 🧪 配套实验：wifi-coproc-labs/ch12-rpi-spidev
> 传输层接口（`xfer`/`drdy_wait`）双实现：**spidev 版**（真 Linux：三 ioctl + sysfs DRDY 轮询，`zig cc -target x86_64-linux` 交叉编译验证入库）与 **fake 版**（内存对端 echo 从机，Windows 上真实运行）：守护进程主循环 + PING/echo 数据在 fake 传输层上全链跑通（复用 ch03/05 协议源文件，零改动）。源码直达：[transport_spidev.c（代码浏览）](/static/code/#/wifi-coproc-labs/ch12-rpi-spidev/transport_spidev.c)、[hostd.c](/static/code/#/wifi-coproc-labs/ch12-rpi-spidev/hostd.c)、[完整工程](/static/code/#/wifi-coproc-labs/ch12-rpi-spidev/README.md)、[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/tree/v4/practice/wifi-coproc-labs/ch12-rpi-spidev)。

## 12.5 小结

- spidev 三个 ioctl = 模式/速度/交换；`SPI_IOC_MESSAGE` 一次双向搬 N 字节，与 ch02 交换语义同构；bufsiz 默认 4096 是交换尺寸的隐形天花板。
- DRDY 事件化两路：libgpiod（推荐）/sysfs 轮询（零依赖骨架）；EXTI 向量与 poll 事件是同一件事的两种世界观。
- 守护进程主循环 = poll 事件泵（DRDY/定时/积压三源）→ exchange → fr_feed → 分发——与 F429 主循环逐行同构，协议中间三层零改动。
- 用户态差价：syscall + 拷贝在低速时钟可忽略、高速显形；批量合并与加大交换是第一对策，内核模块是终极对策；Linux 观测全家桶是隐性收益。

手搓线在 Linux 上立住了，最后一章走官方路：同一块 Korvo-1 刷 ESP-Hosted 从机、RPi4B 装宿主模块拿虚拟网卡——三方（F429 手搓 / RPi 手搓 / RPi 官方）同台对照，多宿主主题收束。[[ch13-rpi-esp-hosted|第十三章：官方路径与多宿主收束]]。
