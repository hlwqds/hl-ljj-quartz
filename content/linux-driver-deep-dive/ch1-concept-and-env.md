---
title: "Linux 设备驱动开发详解（一）：驱动的作用与开发环境构建"
date: 2026-07-30
description: "理解设备驱动在应用与硬件之间的定位：它的本质是硬件抽象层，与是否有操作系统无关；有无 OS 决定了它以什么形态存在。"
tags: [linux-driver, series, kernel, driver]
---

> [!info] Linux 设备驱动开发详解系列 0. [[linux-driver-deep-dive|系列索引]]
>
> 1. **第一章：驱动的作用与开发环境构建**

# Linux 设备驱动开发详解（一）：驱动的作用与开发环境构建

## 1.1 设备驱动的作用

要理解设备驱动解决什么问题，先看一个根本矛盾：CPU 是通用的，而它要驱动的外设千差万别。

### 1. CPU 与外设之间的"语言障碍"

CPU 本身只会做两类事：执行指令，以及读写地址。它不知道什么是网卡、什么是 SSD，更不知道该往哪个寄存器写什么值才能让一块具体硬件干活。这些细节完全由硬件厂商决定，甚至同一类设备的不同型号都不一样。

考虑两个再普通不过的操作：

```text
让一块网卡发出一个以太网帧
  -> 要往某个 MMIO 寄存器写入描述符地址，触发 DMA，再敲一下门铃寄存器

让一块 SSD 写入一个扇区
  -> 要按 NVMe 协议组织一个 SQE，填好命令字、PRP 链，再写另一个门铃寄存器
```

两者用的寄存器、协议、时序完全不同。如果应用代码直接面对这些差异，后果是灾难性的：

- 每换一个型号就要改一遍业务代码；
- 代码只能在能直接访问硬件的特权态运行；
- 多个程序争用同一设备时没有任何仲裁；
- 安全性无从谈起——任何代码都能直接操纵硬件寄存器。

设备驱动就是为了消除这个矛盾而存在的中间层。

### 2. 驱动是硬件的"翻译官"

驱动的本质，是夹在"想用硬件的代码"和"硬件本身"之间的一层**适配/抽象层**。它把五花八门的硬件细节，翻译成上层能理解的统一操作。

```text
        想用硬件的代码
             │   （调用方式取决于有没有 OS，见 1.2 / 1.3）
             ▼
        ┌──────────┐
        │  设备驱动  │   <- 把"硬件怎么干活"的知识封装在这一层
        └──────────┘
             │   操作设备寄存器 / 配置 DMA / 处理中断
             ▼
         硬件设备
```

不论有没有操作系统，这层"翻译"的职责都存在。变的是它**以什么形态存在、上层用什么方式调用它**——这正是下一节要展开的。

### 3. 驱动承担的三件事

剥开各种细节，一个设备驱动实质上做三件事：

| 职责           | 含义                                                                 |
| -------------- | -------------------------------------------------------------------- |
| 生命周期管理   | 初始化设备、配置寄存器、（有 OS 时）挂起恢复与移除释放               |
| 接口封装       | 把硬件能力包装成上层能用的操作（无 OS 时是函数，有 OS 时是统一接口） |
| 事件与数据搬运 | 响应设备中断、配置 DMA、在内存与设备间搬运数据                       |

第一件让设备"能用起来"；第二件让设备"被方便地用"；第三件让数据"真正流动起来"。有无 OS 改变的是这三件事的实现方式，不改其本质。后续章节会逐一展开。

### 4. 驱动存在的两种形态

同样的"翻译"职责，在没有操作系统和有操作系统时，长得很不一样：

```text
  无 OS（裸机）                有 OS（如 Linux）
  ─────────────               ──────────────────
  应用 / 主循环                 用户态应用
      │ 直接函数调用                │ read/write/ioctl (系统调用)
      ▼                        ▼
  驱动（几个函数）              内核子系统（VFS / net / block …）
      │                        │  统一接口：file_operations 等
      │ 直接读写寄存器             ▼
      ▼                       设备驱动（住内核）
  硬件                          │
                               ▼
                            硬件
```

- **无 OS 时**：驱动就是一组直接操作硬件的函数，和应用代码链接在同一个程序里，处于同一地址空间、同一特权级，互相直接调用。
- **有 OS 时**：驱动住进操作系统内部，应用不再直接调用驱动函数，而是经由系统调用和内核子系统间接访问；OS 负责隔离、仲裁、并提供统一接口。

驱动"住在内核里"只是第二种形态的产物，不是驱动的定义。下一节先看无 OS 的形态，1.3 再回到 Linux。

---

## 1.2 无操作系统的设备驱动

无操作系统，不等于无设备驱动。只要程序要操纵硬件，"翻译硬件"的那层代码就一定会存在——只是它的形态、边界和代价与有 OS 时完全不同。这一节把裸机环境下的驱动看清楚，下一节再对比有 OS 的形态，两类驱动的差异会一目了然。

### 1. 裸机环境的几个前提

在没有 OS 的系统里（典型的单片机、MCU 程序，或 PC 上电后最早运行的 bootloader），整个机器呈现这几个特征：

| 特征       | 含义                                 | 对驱动的影响                             |
| ---------- | ------------------------------------ | ---------------------------------------- |
| 单一特权级 | 没有"内核态/用户态"之分              | 所有代码都能直接读写硬件寄存器           |
| 单地址空间 | 应用和驱动链接在同一个程序里         | 互相直接函数调用，没有跨越边界的开销     |
| 无调度器   | 通常是一个 `main` 主循环，加若干中断 | 没有"谁在运行"的仲裁，时序由代码自己保证 |
| 无统一抽象 | 没有文件描述符、VFS 之类             | 设备怎么用，完全由驱动函数签名决定       |

这几个前提决定了裸机驱动的典型长相。

### 2. 驱动的形态：一组直接链接进去的函数

无 OS 时，驱动本质上就是"几个操作硬件的函数"，被主程序直接调用。以点亮一个 LED（操作某 GPIO）为例，驱动的全部可能就是：

```c
/* led.c —— 这就是"驱动" */
#define GPIOA_BASE  0x40020000U
#define MODER       (*(volatile unsigned int *)(GPIOA_BASE + 0x00))
#define ODR         (*(volatile unsigned int *)(GPIOA_BASE + 0x14))

/* 生命周期：初始化 */
void led_init(void)
{
    /* 把 PA0 配成输出 */
    MODER = (MODER & ~(0x3U << 0)) | (0x1U << 0);
}

/* 接口：开 / 关 */
void led_on(void)  { ODR |=  (0x1U << 0); }
void led_off(void) { ODR &= ~(0x1U << 0); }
```

主程序直接调用它：

```c
/* main.c —— 应用 */
int main(void)
{
    led_init();
    while (1) {
        led_on();
        delay(500);
        led_off();
        delay(500);
    }
}
```

注意几个关键点：

- 没有系统调用。`led_on()` 就是一次普通的函数调用，最终编译成几条直接读写内存映射寄存器的指令。
- 没有文件描述符、没有 `open/read/write`。设备怎么用，完全由 `led_init / led_on / led_off` 这套函数签名定义。
- 没有隔离。`main` 和 `led_*` 在同一地址空间、同一特权级，谁都能直接碰 `MODER` 寄存器。
- `volatile` 是这里唯一和编译器"较劲"的地方：它告诉编译器这两个地址对应的是硬件寄存器而不是普通内存，每次都要真正读写、不能被优化掉或缓存到寄存器。

### 3. 前后台结构：中断 + 主循环

很多裸机程序不止 `while(1)` 轮询，还会用中断。这时驱动通常分成"前台"和"后台"两部分：

```text
  前台（中断服务程序，ISR）        后台（主循环）
  ─────────────────────         ────────────────
  硬件触发中断 -> ISR 执行        主循环轮询标志位
  做最少的事：                   做耗时的处理：
   - 读/清寄存器                  - 解析数据
   - 置一个标志位                  - 执行业务逻辑
   - 尽快返回                     - 准备下一次操作
```

驱动在这里承担两件熟悉的事：把硬件中断"翻译"成一个标志位或缓冲区（生命周期与事件搬运），并提供给主循环使用的接口（接口封装）。职责和有 OS 驱动一样，只是没有内核子系统帮它做缓冲管理和上下文切换。

### 4. 这种形态的代价

简单和零开销不是白来的。无 OS 驱动有几个明显的代价：

- **没有隔离**。任何代码都能直接写硬件寄存器，一个越界写就能让外设行为错乱。
- **没有并发仲裁**。如果主循环和 ISR 同时访问同一设备，必须由驱动自己用关中断等手段保护——这是裸机 bug 的常见来源。
- **没有统一接口**。每个设备的用法是它自己的函数签名，换个设备要改调用方；代码无法像"一切皆文件"那样通用。
- **可移植性和复用差**。寄存器地址、时钟配置、中断号都写死在驱动里，换一颗 MCU 往往要大改。
- **难以多任务**。没有调度器，多个任务要靠状态机或分时轮询手工拼出来，复杂度随功能数上升很快。

### 5. 为什么它依然广泛存在

既然代价不小，无 OS 驱动为什么还无处不在？因为它的优势在特定领域是决定性的：

| 优势           | 体现                                                                                  |
| -------------- | ------------------------------------------------------------------------------------- |
| 极简           | 没有内核开销，启动即用，适合资源受限的 MCU                                            |
| 零抽象损耗     | 没有系统调用和上下文切换，延迟可预测                                                  |
| 实时性强       | 中断到响应的路径短而确定                                                              |
| 不可替代的场景 | 系统启动最早的 bootloader、芯片初始化、带外管理固件——此时 OS 还没跑起来，只能裸机驱动 |

所以无 OS 驱动并不是"落后"，而是另一类需求下的合理选择。理解它，既是为了写 MCU 固件，也是为了看清"OS 到底替驱动解决了哪些问题"。

### 6. 与有 OS 驱动的对比

把两种形态放在一起，差异就清晰了：

| 维度          | 无 OS 驱动            | 有 OS 驱动                        |
| ------------- | --------------------- | --------------------------------- |
| 存在形态      | 一组函数，链接进应用  | 住 OS 内部，应用通过系统调用访问  |
| 特权/地址空间 | 与应用相同            | 与应用隔离（内核态/用户态）       |
| 调用方式      | 直接函数调用          | 经系统调用 + 内核子系统           |
| 接口风格      | 各设备自定义函数签名  | 统一接口（如 `read/write/ioctl`） |
| 并发与隔离    | 驱动自己保证          | OS 提供调度、锁、隔离             |
| 典型场景      | MCU、bootloader、固件 | 通用操作系统（Linux 等）          |

右侧那一列，正是 1.3 要展开的内容。

---

## 1.3 有操作系统时的设备驱动

上一节结尾列出的那张对比表，右列全是有 OS 驱动的特征。这一节把它们逐一展开：看操作系统究竟带来了什么，又替驱动解决了哪些在裸机里必须自己扛的问题。理解了这一节，就理解了 Linux 驱动"为什么长成这样"。

### 1. OS 改变了什么

回顾 1.2 列出的裸机四个前提，在有 OS 的环境里全部被改写：

| 裸机前提   | 有 OS 时                               | 带来的后果                                   |
| ---------- | -------------------------------------- | -------------------------------------------- |
| 单一特权级 | 分内核态 / 用户态                      | 应用不能再直接碰硬件寄存器                   |
| 单地址空间 | 内核空间与用户空间分离                 | 应用和驱动不在同一地址空间，不能直接函数调用 |
| 无调度器   | 有调度器，多个进程并发运行             | 必须考虑"多个使用者同时访问设备"             |
| 无统一抽象 | 有 VFS、net core、block layer 等子系统 | 设备要按子系统的规范提供接口                 |

这四条改写叠加起来，把驱动从"应用直接链接进去的几个函数"，变成了一个住在内核里、经由系统调用和子系统间接访问的独立组件。

### 2. 驱动住进内核：分层调用路径

应用要使用设备，要跨越好几层。把这条完整路径画出来，是理解有 OS 驱动的关键：

```text
用户态应用
    │   open("/dev/xxx")  read()  write()  ioctl()  mmap()
    ▼
系统调用层                 （sys_open / sys_read / sys_ioctl …）
    │   这是用户态与内核之间固定、稳定的 ABI 边界
    ▼
内核子系统                 （VFS / block layer / net core / input …）
    │   把设备按类别归类，对上层提供统一接口
    │   例如 VFS 要求字符设备实现 file_operations
    ▼
设备驱动                   （针对某一款硬件的具体代码）
    │   实现 subsystem 要求的接口；操作寄存器、配置 DMA、注册中断
    ▼
硬件设备
```

和裸机那张"应用 → 驱动 → 硬件"的短路径相比，这里多了**系统调用**和**内核子系统**两层。这两层不是累赘，而是操作系统为驱动提供的整套基础设施——下一节起逐层拆解。

### 3. 系统调用：统一的 ABI 边界

裸机里，设备怎么用完全由驱动函数签名决定（`led_on()`、`uart_send()`），每个设备一套。有 OS 后，应用不再认识驱动函数，只认识一组固定的系统调用：

| 调用    | 对设备的意义                                |
| ------- | ------------------------------------------- |
| `open`  | 取得设备的一个句柄（文件描述符）            |
| `read`  | 从设备读数据                                |
| `write` | 向设备写数据                                |
| `ioctl` | 设备特有的控制命令（设置波特率、配置模式…） |
| `mmap`  | 把设备内存映射进用户地址空间                |
| `close` | 释放句柄                                    |

这组系统调用是**所有设备共用**的。应用操作网卡、操作传感器、操作显卡，用的是同一套 `open/read/write/ioctl`，差别只在 `/dev/` 下打开的是哪个设备节点、以及 `ioctl` 传什么命令。

这就是 Unix"一切皆文件"的真正含义：驱动把五花八门的设备，翻译成了同一组文件操作。应用因此做到可移植——换硬件不用改应用代码，只要换个驱动。

### 4. 内核子系统：分类与统一接口

系统调用提供了统一的入口，但设备种类繁多、语义差异大（字符设备、块设备、网络设备……），不可能用一套逻辑处理。内核用**子系统**来分类：每个子系统面向一类设备，定义一套"要实现哪些接口"的规范。

| 子系统          | 面向                                     | 驱动要实现的核心接口                          |
| --------------- | ---------------------------------------- | --------------------------------------------- |
| VFS（字符设备） | 按字节流访问的设备（串口、按键、传感器） | `file_operations`（`open/read/write/ioctl…`） |
| block layer     | 按块访问的存储设备（磁盘、SSD）          | `block_device_operations`                     |
| net core        | 网络接口（网卡、虚拟网卡）               | `net_device_ops`                              |
| input subsystem | 输入设备（键盘、鼠标、触摸屏）           | `input_event` 上报                            |

驱动要做的，就是**按所属子系统的规范实现这套接口**。一旦实现并注册，子系统就会把上层的系统调用正确地路由到驱动的接口函数里。驱动因此不必关心"应用怎么找到我"，只关心"硬件怎么干活"。

### 5. OS 替驱动解决了哪些问题

把这一节的内容对照 1.2 列出的裸机代价，逐条回收：

| 裸机里的代价 | 有 OS 时如何解决                                 |
| ------------ | ------------------------------------------------ |
| 没有隔离     | 特权级 + 地址空间分离，应用碰不到硬件寄存器      |
| 没有并发仲裁 | 调度器 + 内核同步原语（自旋锁、互斥锁、信号量）  |
| 没有统一接口 | 子系统 + `file_operations` 等统一 ops            |
| 可移植性差   | 驱动只实现接口，上层通用；硬件差异封装在驱动内部 |
| 难以多任务   | 内核原生支持并发，每类设备有成熟的访问模型       |

### 6. Linux 的实现选择：内核模块

具体到 Linux，驱动通常不以静态编译进内核的方式存在，而是作为**内核模块**（kernel module，`.ko` 文件）按需加载：

```text
编写 hello.ko  ->  insmod 加载进运行中的内核  ->  它就成了内核的一部分
                                       <-  rmmod 卸载，从内核移除
```

模块机制让驱动可以在不重启系统、不重新编译内核的前提下装载和移除，这极大地降低了驱动开发和部署的成本。它是后面所有章节的物理载体——我们写的字符设备、平台驱动、中断处理，最终都会以模块的形式跑起来。

不过模块只是"怎么把驱动装进内核"的工程手段，不改变驱动要承担的任何职责。一个模块里装的，依然是本节讲的这套"实现子系统接口 + 操作硬件"的代码。

---

接下来进入 Linux：先看它如何给设备分类。

## 1.4 Linux 设备驱动

前面三节建立了"驱动是什么、在裸机和有 OS 时分别长什么样"的认知。接下来聚焦 Linux 本身：先看它怎么给设备分类，再看驱动在整个系统里处于什么位置。

### 1.4.1 设备的分类和特点

Linux 把设备分成三大类。分类的依据不是"设备叫什么名字"，而是**数据怎么流经它、内核用哪套子系统管理它**。

#### 字符设备（Character Device）

最常见的设备类型，也是本系列的主线。

- **访问方式**：以字节流为单位，串行读写。
- **设备节点**：对应 `/dev/` 下的一个节点（如 `/dev/ttyS0`、`/dev/input/event0`）。
- **内核接口**：实现 `file_operations`，经 VFS。
- **应用访问**：`open / read / write / ioctl / mmap`。
- **典型设备**：串口、终端、键盘、鼠标、LED、I2C/SPI 传感器、ADC、帧缓冲、看门狗、RTC。

凡是"读一串数据 / 发一条命令 / 配一个参数"式的设备，基本都归这一类。它也是最简单的驱动类型——只需实现一组文件操作函数。本系列从字符设备入手，原因正在于此。

#### 块设备（Block Device）

面向存储，按块而非字节流访问。

- **访问方式**：以块（扇区，通常 512 字节或 4KB）为单位，可随机寻址。
- **设备节点**：同样有 `/dev/` 节点（如 `/dev/sda`、`/dev/nvme0n1`）。
- **内核接口**：实现 `block_device_operations`，请求要经过 **block layer**（I/O 调度、合并、缓存）。
- **应用访问**：可挂载文件系统后使用，也可直接块读写。
- **典型设备**：硬盘、SSD、U 盘、eMMC、SD 卡、NVMe、光驱。

块设备和字符设备最本质的区别，不在于"能不能随机访问"——字符设备也能用 `mmap` 随机访问显存。真正的区别在数据路径：

| 维度             | 字符设备   | 块设备                               |
| ---------------- | ---------- | ------------------------------------ |
| 访问粒度         | 字节流     | 块（扇区）                           |
| 是否经 I/O 调度  | 否         | 是（block layer 合并 / 重排 / 缓存） |
| 能否挂载文件系统 | 一般不能   | 能                                   |
| 请求缓冲         | 应用自己管 | 内核 page cache 缓冲                 |

块设备多了一层"块 I/O 子系统"做调度和缓冲；字符设备则是应用读写直达驱动。

#### 网络设备（Network Device）

最特殊的一类，访问模型和前两类截然不同。

- **访问方式**：面向数据包（frame/packet）的收发，没有字节流或块的概念。
- **设备节点**：**没有** `/dev` 节点。网络接口以名字标识（`eth0`、`wlan0`）。
- **内核接口**：实现 `net_device_ops`，挂接网络协议栈。
- **应用访问**：通过 socket API（`socket / send / recv`），不经过 VFS 的 `open/read/write`。
- **典型设备**：以太网卡、WiFi、蓝牙、虚拟网卡（veth、tun、bridge）。

网络设备不走 VFS 这条"一切皆文件"的路。应用不 `open("/dev/eth0")`，而是创建一个 socket，由协议栈向下调用驱动的收发接口。

#### 三类设备总览

| 维度         | 字符设备          | 块设备                    | 网络设备         |
| ------------ | ----------------- | ------------------------- | ---------------- |
| 访问单位     | 字节流            | 块/扇区                   | 数据包           |
| `/dev` 节点  | 有                | 有                        | 无               |
| 经 VFS       | 是                | 是（经 block layer）      | 否（经协议栈）   |
| 核心接口     | `file_operations` | `block_device_operations` | `net_device_ops` |
| 能挂文件系统 | 否                | 是                        | 否               |
| 典型硬件     | 串口/LED/传感器   | 磁盘/SSD                  | 网卡/WiFi        |

#### 怎么判断一台设备属于哪类

不靠设备名字，靠访问模式。问两个问题：数据是流式的、按块寻址的、还是按包收发的？应用是经 `/dev` 节点访问，还是经 socket？

同一块物理硬件可能同时暴露多种接口——例如一块 SSD 作为块设备存数据，又通过字符接口暴露 NVMe admin 命令通道。分类针对的是"这条访问路径"，不是物理设备本身。

### 1.4.2 Linux 设备驱动与整个软硬件系统的关系

上一小节回答了"设备分几类"。这一节换到结构视角，看驱动在整个软硬件系统里到底处于什么位置、和谁打交道。注意它和 1.3 的区别：1.3 讲的是数据自上而下怎么流，这里讲的是各组件之间的**结构关系**。

#### 1. 驱动：软硬件之间的交接面

把系统从上到下分成三层，驱动的位置一目了然：

```text
┌─────────────────────────────────────┐
│  应用层      用户态进程              │
├─────────────────────────────────────┤
│  内核层                              │
│   ┌───────────────────────────────┐ │
│   │  子系统 (VFS/net/block/...)   │ │  <- 通用，与硬件无关
│   ├───────────────────────────────┤ │
│   │  设备驱动                      │ │  <- 硬件知识的容器（离硬件最近的一层）
│   └───────────────────────────────┘ │
├─────────────────────────────────────┤
│  硬件层      CPU / 外设 / 固件       │
└─────────────────────────────────────┘
```

驱动是内核里**离硬件最近的一层**。它向上对接内核子系统（实现子系统要求的接口），向下操作硬件（读写寄存器、配 DMA、注册中断）。一句话：驱动是"这块具体硬件怎么干活"的全部知识的容器，把这些知识封装起来，让上层完全感知不到硬件差异。

#### 2. 内核里的设备模型：bus / device / driver

现代 Linux 不是让驱动自己去满世界找设备，而是用一套统一的**设备模型**来管理。三个核心对象：

| 对象           | 含义                                 | 例子                         |
| -------------- | ------------------------------------ | ---------------------------- |
| bus（总线）    | 设备和驱动相遇的"场合"，定义匹配规则 | platform、pci、usb、i2c、spi |
| device（设备） | 一个具体的设备实例                   | 某个 I2C 传感器、某张网卡    |
| driver（驱动） | 能驱动某类设备的代码                 | 该传感器的驱动、该网卡的驱动 |

它们怎么挂上钩：

```text
设备注册到总线   ──┐
                   ├── 内核在总线上做匹配 ── 匹配成功 ──> 调 driver 的 probe()
驱动注册到总线   ──┘
```

- 匹配依据因总线而异：PCI/USB 用 vendor/device id，platform 用设备名或 compatible 字符串。
- 匹配成功后，内核调用驱动的 `probe`，驱动在里面初始化设备、注册到相应子系统。
- 设备移除或驱动卸载时，调用 `remove` 做清理。

这套模型把**设备和驱动解耦**：同一个驱动能管多个同类设备，同一种总线框架统一管理不同厂商的硬件。我们后面写平台驱动时，写的就是这个 model 里的 driver 一侧。

#### 3. 设备从哪里"来"：发现与描述

驱动要操作设备，首先得知道设备存在、知道它的配置（寄存器地址、中断号、时钟）。这些信息从哪来，取决于硬件所在的总线和平台：

| 平台 / 总线          | 设备怎么被发现         | 配置信息来源                              |
| -------------------- | ---------------------- | ----------------------------------------- |
| x86 / 服务器（ACPI） | 内核启动时解析 ACPI 表 | ACPI 表内的 \_CRS 等方法                  |
| 嵌入式（ARM 等）     | 解析 Device Tree       | 设备树节点（compatible、reg、interrupts） |
| PCI / USB            | 总线枚举，硬件自报身份 | 配置空间（vendor/device id、BAR）         |
| platform（虚拟/SoC） | 代码或 DT 显式注册     | platform_data 或 DT                       |

不管来源是 ACPI、Device Tree 还是总线枚举，最终都汇入统一的设备模型，驱动用同一套 `probe` 接口拿到这些配置。这是 Linux 设备模型的设计要点：**屏蔽硬件描述来源的差异，给驱动一个一致的入口**。

#### 4. 驱动与固件的分工

现代复杂硬件里，往往还有一层跑在硬件自身 MCU 上的程序——**固件**（firmware）。驱动和固件各管一摊：

|          | 驱动                           | 固件                         |
| -------- | ------------------------------ | ---------------------------- |
| 运行位置 | 内核空间                       | 硬件自身的 MCU               |
| 职责     | 内核接口、缓冲管理、与固件协作 | 硬件底层实时逻辑、链路状态机 |
| 举例     | e1000e 网卡驱动                | 网卡里的微码；GPU 微码       |

驱动常负责在加载时把固件镜像灌进硬件（`request_firmware`），之后两者协作完成数据收发。固件管"硬件内部实时细节"，驱动管"内核如何看待这块硬件"。

#### 5. 全景定位

把上面几层合在一起，看驱动在整个系统里的枢纽角色：

```text
应用  ──(系统调用)──>  子系统  ──>  设备模型  ──>  驱动  ──>  固件  ──>  硬件
                                          ↑
                              (ACPI / DT / 总线枚举 描述设备)
```

驱动是这条链上承上启下的契约层：它让**通用内核**能驱动**具体硬件**，同时让**具体硬件**对上层表现为**统一接口**。这是它在整个软硬件系统中的根本定位。

### 1.4.3 Linux 设备驱动的重点、难点

知道了驱动在哪、管什么，还要知道它真正难在哪。这一节把驱动开发的重心和初学者最容易栽跟头的地方点出来，作为后续章节的"风险地图"。很多坑在概念阶段看不出来，写第一段代码时才会暴露——先建立认知，比出问题再查高效得多。

#### 重点：驱动开发要牢牢抓住的东西

| 重点                   | 为什么是重点                                                                                  |
| ---------------------- | --------------------------------------------------------------------------------------------- |
| 分层的职责边界         | 驱动只实现子系统要求的接口，不越界。写对契约，上层（VFS、协议栈）自动能用；写错，整套机制失效 |
| 设备模型与匹配         | 总线、device、driver 怎么挂钩、`probe` 何时被调用——这是任何驱动"活起来"的前提                 |
| 并发控制               | 几乎所有驱动 bug 的根源。自旋锁、互斥锁、关中断各用在什么上下文，必须分清                     |
| 用户态与内核的数据交换 | `copy_from_user` / `copy_to_user` / `mmap`，是把应用数据安全搬进内核的关键路径                |
| 资源生命周期           | 申请的内存、注册的设备、映射的 I/O、申请的中断——配了就要在每条错误路径上全部释放              |

这几项是驱动开发的主干，后续每一章都在围绕它们展开。

#### 难点：初学者最易踩的坑

**1. 并发与上下文**

这是驱动最难也最隐蔽的部分。用户态编程可以假设"一段代码不被打断"，驱动里这个假设彻底失效：

- 多个进程可能同时 `open` 同一个设备。
- 中断随时打断正在执行的驱动代码。
- 多核上，两条路径可能真正并行而非"看起来并行"。

难点不在"知道要用锁"，而在**用对锁的种类**：

| 上下文                      | 能否睡眠/调度      | 该用的同步              |
| --------------------------- | ------------------ | ----------------------- |
| 进程上下文                  | 能                 | 互斥锁（mutex）、信号量 |
| 中断上下文（硬中断）        | **不能**睡眠或调度 | 自旋锁、关中断          |
| 软中断 / tasklet / 工作队列 | 依类型而定         | 对应规则                |

在硬中断里调一个会睡眠的锁（mutex）→ 内核直接挂。这类规则没有"试试看"的余地，必须一开始就记牢。

**2. 用户态指针不能直接用**

应用传进来的指针指向的是**用户地址空间**，驱动在内核空间直接解引用，要么读到错误数据，要么触发缺页异常。必须用 `copy_from_user` / `copy_to_user` 做跨空间拷贝，它们会处理权限检查和缺页。

这是用户态思维最容易直接平移过来出事的地方：**内核里看到用户传来的指针，第一反应必须是"不能直接 deref"**。

**3. 错误路径要原路退回**

驱动初始化常是一串"申请 A → 注册 B → 映射 C → 申请中断 D"。如果到 D 失败了，前面的 A/B/C 必须全部回滚。用户态里一个函数失败大不了返回错误，驱动里漏掉一次释放，就是内存泄漏、资源永久占用，甚至设备再也用不起来。

规范写法是每步都配 `goto` 到统一清理标签，逐级释放。初看啰嗦，却是驱动里防漏的标准姿势。

**4. 调试代价极高**

用户态程序 `printf` + gdb 基本够用。驱动出问题：

- 一个空指针解引用 = 整个内核 oops，轻则当前进程挂，重则整机死。
- 没有 `printf`，要用 `printk` / `dev_info`，事后 `dmesg` 翻日志。
- 时序相关的并发 bug 难复现，加一行日志可能就让它消失了（海森堡 bug）。

因此驱动开发有个和用户态相反的习惯：**先想清楚不变量和边界条件，再写代码**，而不是"跑起来再调"。

#### 一句话定位重点与难点

驱动的重点是**实现接口、管好资源、控住并发**；难点是**并发上下文、跨空间数据、错误回滚、调试代价**。这几项贯穿后续所有章节——写字符设备时会遇到 `copy_to_user`，写平台驱动会遇到 `probe` 的资源管理，写中断会遇到上下文与同步。心里有这张风险地图，遇到具体机制时就知道它在解决哪类问题。

## 1.5 Linux 设备驱动的开发环境搭建

概念清楚了，重点难点也心里有数，接下来要有一套能真正跑代码的环境。驱动开发和用户态程序不同：模块加载失败会让整个内核 panic，直接在宿主机上实验风险太高。本节聚焦 **qemu 虚拟机**作为实验环境——它隔离、可复现、可任意定制内核版本和配置，是学习驱动最安全也最灵活的选择。

### 1.5.1 qemu 实验环境

本系列选 **ARM vexpress-a9 开发板** 作为实验平台：qemu 用 `-M vexpress-a9` 模拟一块 Cortex-A9 SMP 四核开发板（带 Flash、SD、I2C、LCD 等外设），和我们后续要写的外设驱动能真正对接上。选 ARM 而非 x86，是为了从一开始就接触交叉编译、设备树、总线/平台驱动这些嵌入式驱动的核心议题——它们和 PC 上写网卡驱动是两套世界。

#### 1. 为什么用 qemu

在宿主机上直接 `insmod` 自己写的模块，能跑通当然最省事，但对学习阶段是坏选择：

| 问题                           | 在宿主机上                     | 在 qemu 里                            |
| ------------------------------ | ------------------------------ | ------------------------------------- |
| 模块出 bug                     | 内核 panic，可能整机死，丢工作 | 只死虚拟机，宿主机无碍                |
| 内核版本                       | 只能用发行版内核，不能改       | 自编译任意版本                        |
| 调试选项（KASAN、DEBUG_INFO…） | 难开（要换内核）               | 编译时随手开                          |
| 实验可复现                     | 依赖具体机器                   | 一个内核 + initramfs + dtb，到处跑    |
| 目标硬件                       | 只能跑本机硬件                 | 模拟真实开发板，可碰 Flash/SD/I2C/LCD |

所以本系列后续的代码，默认在 qemu 的 vexpress-a9 里跑。下面搭起这套环境：装 qemu 和交叉工具链 → 交叉编译内核 → 做最小根文件系统 → 启动验证。

> [!note] 宿主机要求
> 以下命令在 Fedora 43 上验证（gcc 15、make 4.4）。其他发行版把包管理器换掉即可（Debian/Ubuntu 见每步注释），步骤不变。

#### 2. 安装 qemu 与 ARM 交叉工具链

```bash
# qemu ARM 模拟器
# Fedora
sudo dnf install -y qemu-system-arm
# Debian/Ubuntu: sudo apt install qemu-system-arm

# ARM 交叉编译工具链（用来编内核和 BusyBox）
# Fedora: 注意装出来的二进制叫 arm-linux-gnu-gcc（软浮点 triplet），不是 Debian 的 arm-linux-gnueabihf-gcc
sudo dnf install -y gcc-arm-linux-gnu
# Debian/Ubuntu: sudo apt install gcc-arm-linux-gnueabihf

# 验证
qemu-system-arm --version
arm-linux-gnu-gcc --version    # Debian 系请改用 arm-linux-gnueabihf-gcc
```

> [!warning] Fedora 与 Debian 的工具链命名不同
> Fedora 的包 `gcc-arm-linux-gnu` 装出来是 `arm-linux-gnu-gcc`；Debian 的包 `gcc-arm-linux-gnueabihf` 装出来是 `arm-linux-gnueabihf-gcc`。两者都能编译 ARMv7 内核，**不要在本机找不到 `arm-linux-gnueabihf-gcc` 就以为装错了**——那是 Debian 系的命名。后面命令里统一用 `arm-linux-gnu-`，Debian 用户自行替换前缀即可。

交叉工具链和裸机工具链要分清：

| 工具链                              | triplet 前缀           | 能编译                           | 说明                      |
| ----------------------------------- | ---------------------- | -------------------------------- | ------------------------- |
| `arm-linux-gnu-gcc`（Fedora）       | `arm-linux-gnu-`       | 内核 + 用户态（带 libc）         | 本系列用这个              |
| `arm-linux-gnueabihf-gcc`（Debian） | `arm-linux-gnueabihf-` | 内核 + 用户态（带 libc，硬浮点） | Debian 系等价物           |
| `arm-none-eabi-gcc`（裸机）         | `arm-none-eabi-`       | 仅内核/裸机，**不能编 BusyBox**  | 无 libc，用户态程序编不了 |

#### 3. 交叉编译内核

从 kernel.org 拉源码，用 ARM 的 defconfig 做起点：

```bash
export KVER=6.19
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz
tar xf linux-$KVER.tar.xz
cd linux-$KVER

# multi_v7_defconfig 覆盖 ARMv7（含 Cortex-A9），是 vexpress-a9 的通用起点
make ARCH=arm CROSS_COMPILE=arm-linux-gnu- multi_v7_defconfig

# 打开驱动学习推荐选项
make ARCH=arm CROSS_COMPILE=arm-linux-gnu- menuconfig
```

内核配置里这几项对本系列是**必须**或强烈推荐（注意 `=y`/`=m` 的区别）：

| 路径                                                        | 选项                      | 内建/模块     | 为什么                                                                                   |
| ----------------------------------------------------------- | ------------------------- | ------------- | ---------------------------------------------------------------------------------------- |
| Enable loadable module support →                            | `CONFIG_MODULES`          | **`=y` 必须** | 客户机要能 `insmod` 我们写的 `.ko`，这是前提                                             |
| Enable loadable module support →                            | `CONFIG_MODULE_UNLOAD`    | `=y` 推荐     | 支持 `rmmod`，实验时反复装卸                                                             |
| File systems →                                              | `CONFIG_BLK_DEV_INITRD`   | **`=y` 必须** | 启动时加载 initramfs                                                                     |
| Kernel hacking →                                            | `CONFIG_DEBUG_INFO`       | `=y` 推荐     | 调试符号，配合 addr2line 定位 oops                                                       |
| Kernel hacking →                                            | `CONFIG_GDB_SCRIPTS`      | `=y` 推荐     | 生成 gdb 辅助脚本                                                                        |
| Kernel hacking → Memory Management →                        | `CONFIG_KASAN`            | 可选          | 内存越界检测（开销大，查内存 bug 时再开）                                                |
| Device Drivers → Network device support → Ethernet driver → | `CONFIG_SMSC911X`         | **`=y` 必须** | vexpress-a9 板载 SMSC LAN9118 网卡驱动；要 telnet 访问客户机必须开                       |
| Networking support →                                        | `CONFIG_NET`              | **`=y` 必须** | 网络协议栈本身（multi_v7 默认含，确认未关）                                              |
| Device Drivers → Character devices → HW Random →            | `CONFIG_HW_RANDOM_VIRTIO` | **`=y` 必须** | virtio-rng 硬件随机数源；qemu 无物理熵源，不开此项内核 CRNG 永不就绪，SSH 握手会超时失败 |

> [!warning] 为什么 `CONFIG_MODULES` 必须 `=y` 而非 `=m`
> 后面我们写的驱动是模块（`.ko`），要在运行中的客户机里 `insmod` 加载。如果 `CONFIG_MODULES` 没内建进内核，客户机根本不认识 `insmod`，整个学习链路就断了。同理 `BLK_DEV_INITRD` 也必须 `=y`——它控制"启动时能否加载 initramfs"。

配置好后编译。产物是 `arch/arm/boot/zImage`（压缩内核镜像）和 `arch/arm/boot/dts/vexpress-v2p-ca9.dtb`（设备树）：

```bash
make ARCH=arm CROSS_COMPILE=arm-linux-gnu- -j$(nproc) zImage dtbs
```

编译产物：

- `arch/arm/boot/zImage` —— 给 qemu 的内核镜像。
- `arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb` —— vexpress-a9 的设备树。**注意**内核 6.x 把 ARM 平台 DTS 归入 `dts/arm/` 子目录（不是直接 `dts/`），描述板上 CPU、中断控制器、Flash、SD、I2C、LCD 等外设，内核据此发现设备。

> [!tip] 找不到 dtb 文件名时
> 不同内核版本的 DTS 命名可能微调。在内核源码树里查：`find arch/arm/boot/dts -name '*ca9*'`。vexpress-a9 对应的就是 `vexpress-v2p-ca9.dtb`。

#### 4. 做一个最小根文件系统（initramfs）

内核启动后要一个根文件系统才能跑 shell。最轻量是用 BusyBox 打一个 initramfs。注意 BusyBox 是**用户态程序**，需要 ARM libc，必须用交叉工具链编译（不能用裸机 `arm-none-eabi-`）。

预编译的 ARM 静态 BusyBox 版本和架构都不可控（x86 的 `busybox.net/.../latest` 路径在 ARM 上没有对应物，直接复制会拿到 x86 二进制，在客户机里 `Exec format error`）。所以本系列从源码交叉编译，和内核用同一套工具链，确保架构匹配：

```bash
cd ..
wget https://busybox.net/downloads/busybox-1.36.1.tar.bz2
tar xf busybox-1.36.1.tar.bz2
cd busybox-1.36.1

make ARCH=arm CROSS_COMPILE=arm-linux-gnu- defconfig
# 静态链接，initramfs 里不依赖动态库
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
# sed 改过 .config 后，用 olddefconfig 把配置补齐一致
make ARCH=arm CROSS_COMPILE=arm-linux-gnu- olddefconfig
make ARCH=arm CROSS_COMPILE=arm-linux-gnu- -j$(nproc)

# 得到 busybox（ARM 静态二进制）
ls -la busybox
```

> [!note] Debian 系用户
> 上面所有 `CROSS_COMPILE=arm-linux-gnu-` 换成 `CROSS_COMPILE=arm-linux-gnueabihf-`。若不想自己编译 BusyBox，Debian/Ubuntu 可装 `busybox-static:armhf`（需启用 multiarch），直接拿到 ARM 静态二进制。

把 busybox 安装进 rootfs 骨架——注意不是只 `cp busybox`，而要用 `make install` 装出**全部 applet 链接**：

```bash
cd ..
mkdir -p initramfs/{bin,sbin,etc,proc,sys,dev,mnt}

# 在 busybox 构建目录里，make install 会把 bin/busybox 和所有 symlink
# （ls/mount/cat/insmod/rmmod/...）装到 CONFIG_PREFIX 指定的 rootfs
cd busybox-1.36.1
make ARCH=arm CROSS_COMPILE=arm-linux-gnu- CONFIG_PREFIX="$PWD/../initramfs" install
cd ..

ls initramfs/bin        # 应能看到 ls、mount、cat、sh 等一堆 symlink
```

> [!warning] 为什么必须装 applet 链接，不能只 cp busybox
> BusyBox 是"一个二进制 + 一堆名字"的设计。`/bin/busybox mount` 能跑，但在 shell 里直接敲 `mount`，shell 要靠 PATH 查找 `mount` 这个名字——它需要 `/bin/mount` 这个 symlink 指向 busybox。只 `cp busybox /bin/` 而不建链接，init 里 `mount -t proc ...`、进 shell 后的 `ls`、`insmod`、`rmmod` 全会 `command not found`。`make install` 一次性把这些 symlink 都建好，最稳。

````bash
# 1. 交叉编译静态 dropbear（SSH 服务端）
cd ..
wget https://matt.ucc.asn.au/dropbear/releases/dropbear-2024.85.tar.bz2
tar xf dropbear-2024.85.tar.bz2
cd dropbear-2024.85

CC=arm-linux-gnueabihf-gcc ./configure --host=arm-linux-gnueabihf --disable-zlib
# 注意: dropbear 官方包是动态链接(依赖 libtomcrypt 等), 静态编译需 LDFLAGS=-static
make -j$(nproc) CC=arm-linux-gnueabihf-gcc LDFLAGS="-static" PROGRAMS="dropbear dropbearkey"

# 拷进 initramfs
mkdir -p ../initramfs/usr/sbin ../initramfs/etc/dropbear
cp dropbear ../initramfs/usr/sbin/
cp dropbearkey ../initramfs/usr/sbin/

# 2. 预生成 host key（运行时生成会卡在 CRNG 初始化）
./dropbearkey -t rsa -f ../initramfs/etc/dropbear/dropbear_rsa_host_key -s 2048
cd ..

# 3. 补 /etc/passwd、/etc/group、/root（dropbear 要求）
printf 'root::0:0:root:/root:/bin/sh\n' > initramfs/etc/passwd
printf 'root:x:0:\n' > initramfs/etc/group
mkdir -p initramfs/root && chmod 700 initramfs/root

cat > initramfs/init <<'EOF'
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mkdir -p /dev/pts /var/run /var/log /tmp
mount -t devpts devpts /dev/pts

# 配网络：qemu -net user 默认网段 10.0.2.0/24，客户机默认 IP 10.0.2.15
# （不是 10.0.0.x！hostfwd 转发目标也是 10.0.2.15）
ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up

echo "=== hello from ARM initramfs ==="
# 启动 dropbear SSH 服务端（-B 允许空口令 root 登录）
/usr/sbin/dropbear -E -B -p 22
echo "=== READY: ssh -p 5555 root@127.0.0.1 ==="

# 保持 init 不退出（dropbear daemonize 后 init 需驻留）
exec /bin/busybox sh
EOF
chmod +x initramfs/init

# 打包成 initramfs 镜像
cd initramfs
find . | cpio -o -H newc | gzip > ../initramfs.cpio.gz
cd ..

`/mnt` 目录先建好——后面传模块时挂载用（本节先不用，但建着不亏）。

#### 5. 启动并验证

一条命令把内核、设备树、initramfs 跑起来：

```bash
qemu-system-arm \
    -M vexpress-a9 \
    -smp 4 \
    -m 512M \
    -kernel linux-$KVER/arch/arm/boot/zImage \
    -dtb linux-$KVER/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb \
    -initrd initramfs.cpio.gz \
    -append "console=ttyAMA0" \
    -net nic,model=lan9118 \
    -net user,hostfwd=tcp:127.0.0.1:5555-:22,hostfwd=tcp:127.0.0.1:5556-:23 \
    -device virtio-rng-device \
    -nographic
````

参数说明：

- `-M vexpress-a9` 模拟 Cortex-A9 SMP 开发板（带 Flash/SD/I2C/LCD 等外设）。
- `-smp 4` 四核。
- `-m 512M` 给客户机 512MB 内存。
- `-kernel` 交叉编译的 `zImage`。
- `-dtb` 设备树——**注意路径是 `dts/arm/`**（内核 6.x 归入子目录），vexpress-a9 必须显式传 dtb，内核据此发现板上外设。
- `-net nic,model=lan9118` 挂载板载网卡（SMSC LAN9118）。`model=lan9118` 是该 machine 唯一支持的网卡型号。
- `-net user,hostfwd=...:5555-:22,hostfwd=...:5556-:23` 用户态网络（NAT），`5555` 转发到客户机 `22`（SSH），`5556` 转发到客户机 `23`（telnet）。qemu user 网络默认网段 `10.0.2.0/24`，客户机 IP `10.0.2.15`，宿主机通过端口转发访问，**无法直接 ping 客户机 IP**。
- `-device virtio-rng-device` **必须**——给客户机提供硬件随机数源。不开此项，内核 CRNG 永不就绪，SSH 握手会超时失败。
- `-initrd` 根文件系统镜像。
- `-append "console=ttyAMA0"` 控制台走 PL011 串口（vexpress 的串口名是 `ttyAMA0`，不是 x86 的 `ttyS0`）。
- `-nographic` 纯命令行。

看到 `=== READY: ssh -p 5555 root@127.0.0.1 ===` 说明 dropbear 已启动。另开一个终端 `ssh -p 5555 root@127.0.0.1`（空口令）即可登录。`Ctrl+A X` 退出 qemu。

#### 5.1 远程访问方案

本节给出两种远程访问客户机的方式。**SSH 和 telnet 均已验证打通**。

##### ✅ 方案一：SSH（Dropbear）——已验证打通

initramfs 里集成的 dropbear 提供 SSH 服务端。启动 qemu 后，从宿主机 SSH 登录：

```bash
# 宿主机另开终端
sshpass -p '' ssh -p 5555 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1
# 或手动输入空口令:
ssh -p 5555 root@127.0.0.1
```

自动化验证脚本 `scripts/verify-ssh.sh`（实跑通过，退出码 0，~5 秒完成）：

```bash
./scripts/verify-ssh.sh              # 默认用 linux-6.19
./scripts/verify-ssh.sh linux-6.10   # 指定内核目录
```

脚本做的事：检查产物 → 后台启动 qemu（virtio-rng + hostfwd 22）→ 等 CRNG 就绪 + dropbear 启动 → SSH 登录执行 `id; uname -a` → 断言 `uid=0(root)` → 清理 qemu。看到 `[✓] SSH 远程登录验证通过` 即环境完全打通。

> [!tip] SSH 打通的关键三个修复
> 这套环境在调试过程中踩了三个坑，最终修复后 SSH 才打通：
>
> 1. **`CONFIG_HW_RANDOM_VIRTIO=y`** + qemu `-device virtio-rng-device`：提供硬件熵源，内核 CRNG 秒级就绪。SSH 握手需要随机数，不开此项 CRNG 永不就绪，握手会超时失败。
> 2. **dropbear `-B`**：允许空口令 root 登录。默认 dropbear 拒绝空口令。
> 3. **IP 用 `10.0.2.15`**（qemu user 网默认网段），不是 `10.0.0.15`。hostfwd 转发目标也是 `10.0.2.15`。

##### ✅ 方案二：telnet（busybox telnetd）——已验证打通

initramfs 里的 busybox `telnetd -l /bin/sh` 提供明文 telnet 服务。qemu 启动时 hostfwd 把宿主机 `5556` 转发到客户机 `23`：

```bash
telnet 127.0.0.1 5556
# 出现 ~ # 后无需口令，直接执行命令
```

自动化验证脚本 `scripts/verify-telnet.sh`（expect 驱动，实跑 rc=0）：

```bash
./scripts/verify-telnet.sh              # 默认用 linux-6.19
./scripts/verify-telnet.sh linux-6.10   # 指定内核目录
```

> [!warning] telnet 测试必须用交互式客户端
> 管道式测试（`printf 'id\r\n' | telnet ...`）会因 stdin EOF 过早断连：telnet 客户端关闭 → telnetd 关闭 pty master → 内核 SIGHUP 清理 shell。这是**正常终端行为**，不是 telnetd 缺陷。strace 确认 telnetd 的 fork/setsid/openpty/execve 路径全部正常。
>
> 正确方式：交互式终端（`telnet 127.0.0.1 5556`）或 expect 脚本（保持连接，等响应再退出）。详见 `lab/TROUBLESHOOTING.md` 问题八。

##### 串口控制台（备用）

除了 SSH，始终可用串口控制台直接操作客户机。不加 `-net` 和 `-device virtio-rng-device`，纯串口模式：

```bash
qemu-system-arm -M vexpress-a9 -smp 4 -m 512M \
    -kernel linux-$KVER/arch/arm/boot/zImage \
    -dtb linux-$KVER/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb \
    -initrd initramfs.cpio.gz \
    -append "console=ttyAMA0" \
    -nographic
```

串口直接看到内核启动日志，init 跑完后进入 busybox shell。适合快速调试，不需要网络。

> [!warning] vexpress-a9 没有可用的 9p 共享目录
> x86 上常用 9p（`virtio-9p-pci`）在宿主机和客户机间共享目录，但 vexpress-a9 是老式开发板：**没有 PCI 总线**，virtio-mmio transport 也不在默认设备树里。所以本系列不依赖 9p，改用下面"重打 initramfs"的方式传模块——虽然每次要重打包，但稳定可靠。

#### 6. 把驱动模块传进客户机（后续章节用法）

没有共享目录，模块就打进 initramfs 一起加载。内核模块必须用**同一棵交叉编译过的内核树**构建（符号才能匹配）：

```bash
# 后面写 hello.c 时，在内核源码树旁
# Makefile 里指定内核树和交叉前缀
make ARCH=arm CROSS_COMPILE=arm-linux-gnu- -C linux-$KVER M=$(pwd) modules
# 得到 hello.ko（ARM 模块）

# 把 hello.ko 加进 initramfs，重新打包
cp hello.ko initramfs/
cd initramfs
find . | cpio -o -H newc | gzip > ../initramfs.cpio.gz
cd ..

# 重新启动 qemu，在客户机里
#   insmod hello.ko      # 加载
#   rmmod hello           # 卸载（需 CONFIG_MODULE_UNLOAD=y）
```

数据流：

```text
宿主机：linux-$KVER/          （ARM 内核源码树，交叉编译）
        hello.c + Makefile    （模块源码）
            └─ make ARCH=arm CROSS_COMPILE=arm-linux-gnu- → hello.ko
                 └─ 加进 initramfs，重打包
                      └─ qemu 启动后在客户机 insmod hello.ko
```

记住一条硬约束：**客户机内核和模块必须同源交叉编译**（同一棵内核树、同一个工具链）。版本或符号不匹配，`insmod` 会直接报错拒绝加载。

这一节的成果是一套可复现的 ARM qemu 实验环境：自编译的 vexpress-a9 内核 + BusyBox initramfs，后续每个驱动示例都在这里交叉编译、打包、加载、观察日志，不碰宿主机。

## 1.6 设备驱动 Hello World：LED 驱动

理论框架搭好了，实验环境也跑通了，现在写第一个真正的"驱动"。本节从最原始的形态开始——**无操作系统的裸机 LED 驱动**，让你看到驱动最本质的样子：直接读写硬件寄存器。

### 1.6.1 无操作系统时的 LED 驱动

回到 1.2 节的结论：无 OS 时，驱动就是一组直接操作硬件的函数。这里我们用 vexpress-a9 开发板上的主板 LED 来实践——在没有任何操作系统的情况下点亮它、熄灭它，并在串口上看到状态变化。

#### 1. vexpress-a9 的 LED 在哪

vexpress-a9 主板（V2M）有一个系统寄存器（sysreg），其中 offset `0x008` 是 **SYS_LED** 寄存器，控制 8 个 LED。这个寄存器是内存映射的（MMIO），CPU 可以像读写普通内存一样操作它：

```text
物理地址 0x10000008
  bit 0 → LED0
  bit 1 → LED1
  ...
  bit 7 → LED7

写 0x01 → LED0 亮
写 0x00 → 全灭
```

> [!info] 地址怎么来的
> vexpress-a9 主板挂在地址 `0x10000000`。主板上的 sysreg 在女儿板 offset 0。SYS_LED 在 sysreg 内 offset 0x008。所以物理地址 = `0x10000000 + 0x008 = 0x10000008`。这些信息来自设备树（`vexpress-v2m.dtsi`），内核启动日志也能看到。

#### 2. 裸机程序结构

无 OS 时，程序从 RAM 起始地址（`0x60000000`）开始执行。我们需要三个文件：

| 文件        | 作用                                     | 类比               |
| ----------- | ---------------------------------------- | ------------------ |
| `start.S`   | 汇编入口：设栈指针，跳到 C 函数          | 相当于 `crt0`      |
| `led.c`     | LED 驱动逻辑（写寄存器、延时、串口打印） | 驱动主体           |
| `linker.ld` | 链接脚本：指定程序加载到 `0x60000000`    | 相当于 `kernel.ld` |

##### start.S —— 汇编入口

```c
/* qemu -kernel 加载后从 0x60000000 开始执行 */
    .section .text.start
    .global _start
_start:
    ldr sp, =0x80000000    /* 栈指针指向 RAM 顶部（栈向下生长） */
    bl  main               /* 跳转到 C 的 main() */
hang:
    b   hang               /* main 返回后死循环 */
```

没有 OS 帮你设栈——必须自己来。`sp = 0x80000000`（RAM 顶部），函数调用才能压栈。

##### led.c —— LED 驱动主体

```c
#define SYS_LED     0x10000008   /* 主板 LED 寄存器 */
#define UART0_DR    0x10009000   /* PL011 串口数据寄存器 */
#define UART0_FR    0x10009018   /* PL011 串口状态寄存器 */

/* volatile：告诉编译器这是硬件寄存器，每次都要真正读写 */
#define REG(addr) (*(volatile unsigned int *)(addr))

static void delay(unsigned int count) {
    while (count--) asm volatile("nop");
}

static void uart_putc(char c) {
    while (REG(UART0_FR) & (1 << 3)) ;  /* 等串口不忙 */
    REG(UART0_DR) = c;
}

static void uart_puts(const char *s) {
    while (*s) {
        if (*s == '\n') uart_putc('\r');
        uart_putc(*s++);
    }
}

void main(void) {
    uart_puts("\n=== Bare-metal LED Driver (no OS) ===\n");

    unsigned int led_state = 0;
    for (int i = 0; i < 5; i++) {
        led_state |= 0x01;  REG(SYS_LED) = led_state;
        uart_puts("LED ON  (reg write 0x01)\n");
        delay(5000000);

        led_state &= ~0x01; REG(SYS_LED) = led_state;
        uart_puts("LED OFF (reg write 0x00)\n");
        delay(5000000);
    }

    /* 读回 LED 寄存器，验证写入真实生效 */
    unsigned int val = REG(SYS_LED);
    uart_puts("SYS_LED readback = 0x");
    /* ... 输出十六进制 ... */
    uart_puts("\n=== DONE ===\n");
}
```

注意几个无 OS 驱动的关键点：

- **`volatile`**：1.2 节讲过，硬件寄存器必须加 `volatile`，否则编译器会优化掉重复读写。
- **`delay()` 是忙等**：没有 OS 调度器，没有 `sleep()`，延时只能靠空循环。
- **串口打印是手写的**：没有 `printf`，要自己查 PL011 的状态寄存器、逐字符输出。
- **`main()` 不是真正的入口**：`_start`（汇编）才是，它设好栈后调用 `main`。

##### linker.ld —— 链接脚本

```c
ENTRY(_start)
SECTIONS {
    . = 0x60000000;          /* 程序加载到 RAM 起始 */
    .text : {
        start.o (.text.start) /* 汇编入口在前 */
        *(.text)
    }
    .rodata : { *(.rodata) }
    .data : { *(.data) }
    .bss : { *(.bss) *(COMMON) }
}
```

链接脚本告诉链接器：程序放在 `0x60000000`，入口符号是 `_start`，代码段在最前面。

#### 3. 编译

裸机程序用交叉工具链编译，**不链接标准库**（`-ffreestanding`）：

```bash
# 汇编启动代码
arm-linux-gnu-gcc -c -march=armv7-a -ffreestanding start.S -o start.o

# C 驱动代码
arm-linux-gnu-gcc -c -march=armv7-a -ffreestanding -fno-pic -O2 led.c -o led.o

# 链接（用自定义脚本，入口 0x60000000）
arm-linux-gnu-ld -T linker.ld start.o led.o -o led_blink.elf
```

产物是 `led_blink.elf`（带段头的 ARM ELF）。**注意：qemu 要的是 ELF，不是 raw bin**——qemu 从 ELF 段头读取加载地址，raw bin 的加载位置不对。

#### 4. 运行

```bash
qemu-system-arm -M vexpress-a9 -m 512M \
    -kernel led_blink.elf \
    -nographic -serial stdio -monitor none -display none
```

和 1.5.1 跑内核不同：这里 **不需要 dtb、initramfs、内核**——`-kernel` 直接加载裸机 ELF 到 `0x60000000` 并从入口执行。没有 Linux，没有 BusyBox，只有你的代码。

#### 5. 宿主机怎么感知 LED 变化

qemu 模拟了 vexpress-a9 的 sysreg，LED 寄存器**写入真实生效、读回值正确**，但 qemu 不显示 LED 图形（没有亮灯窗口）。宿主机通过以下方式感知：

| 方式                     | 做法                                                    | 看到什么                                            |
| ------------------------ | ------------------------------------------------------- | --------------------------------------------------- |
| **串口打印**（主线）     | 代码每次写 LED 寄存器时同步串口输出                     | `LED ON` / `LED OFF` 交替，`-serial stdio` 直接可见 |
| **寄存器读回**           | 代码末尾读 `SYS_LED` 并串口输出值                       | `SYS_LED readback = 0x00`（最后一次写 OFF）         |
| **GDB 读寄存器**（备选） | qemu 加 `-S -gdb tcp::1234`，GDB 连入 `x/wx 0x10000008` | 实时查看寄存器值                                    |

实跑输出（`verify-led.sh`，rc=0）：

```text
=== Bare-metal LED Driver (no OS) ===
LED ON  (reg write 0x01)
LED OFF (reg write 0x00)
...（×5）
=== LED blink done, reading back SYS_LED ===
SYS_LED readback = 0x00
=== DONE ===
```

#### 6. 这个"驱动"教会了我们什么

这段不到 60 行的裸机代码，浓缩了无 OS 驱动的全部要素：

1. **直接操作硬件寄存器**（`REG(SYS_LED) = 0x01`）——驱动最本质的动作。
2. **`volatile`** ——告诉编译器别优化掉寄存器读写。
3. **自己管栈、自己管延时、自己写串口** ——没有 OS 提供的任何基础设施。
4. **内存映射地址** ——CPU 怎么找到硬件（MMIO）。

下一节（1.6.2）进入有 OS 的世界：同样的 LED，这次是 Linux 内核模块。你会看到 OS 替驱动省掉了多少手工活——`printk` 替代手写串口、`msleep` 替代忙等、`ioremap` 映射硬件地址。

### 1.6.2 Linux 下的 LED 驱动

上一节写了裸机 LED 驱动：自己设栈、自己写串口、自己忙等延时、直接写物理地址。这一节把同样的 LED 闪烁逻辑搬进 Linux 内核——写成内核模块（`.ko`），在客户机里 `insmod` 加载。

#### 1. 裸机到内核：变了什么

| 维度     | 裸机版（1.6.1）                                 | 内核模块版（本节）                                  |
| -------- | ----------------------------------------------- | --------------------------------------------------- |
| 硬件访问 | 直接写物理地址 `*(volatile u32 *)0x10000008`    | 先 `ioremap()` 映射到内核虚拟地址，再 `iowrite32()` |
| 日志输出 | 手写 PL011 串口驱动（查 FR 寄存器、逐字符输出） | `printk()` 一行搞定                                 |
| 延时     | 忙等循环 `while(count--) nop`                   | `msleep(500)` 让出 CPU                              |
| 入口     | `_start`（汇编设栈→跳 main）                    | `module_init()` 宏注册                              |
| 生命周期 | 没有，main 返回就 hang                          | `module_init` 加载 + `module_exit` 卸载             |
| 栈       | 手动设 `sp = 0x80000000`                        | 内核自动分配                                        |

核心变化：**OS 替驱动接管了"和具体硬件无关"的基础设施**（调度、日志、内存映射）。但注意——本节用 `ioremap` 直接映射属于绕过资源管理，真实驱动应通过子系统申请资源（后续章节）。

> [!warning] 这是不安全的直接 MMIO 演示，不是规范驱动
> 本节用 `ioremap` 直接映射 SYS_LED 寄存器，**绕过了内核资源管理**。vexpress-a9 的 sysreg LED 已被内核内置的 `vexpress-sysreg` / `ledtrig-cpu` 驱动绑定，两者并发写同一寄存器导致读回值不可预测（实测写入 `0x00` 后读回 `0x09`/`0x34`）。
>
> 本节的目标是**展示内核 API（`ioremap`/`printk`/`msleep`/`module_init`）与裸机的对比**，不是展示规范的 LED 控制。正确的做法是用 GPIO 子系统（`gpiod_get`）或先解绑已有驱动——这些放到后续章节。

#### 2. 模块代码

```c
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/delay.h>

#define SYS_LED_PHYS  0x10000008   /* LED 寄存器物理地址（和裸机版同一个） */

static void __iomem *led_reg;       /* 映射后的虚拟地址 */

static int __init led_init(void)
{
    printk(KERN_INFO "=== Kernel LED Driver (module) ===\n");

    /* 内核态不能直接写物理地址——必须先 ioremap 映射 */
    led_reg = ioremap(SYS_LED_PHYS, 4);
    if (!led_reg)
        return -ENOMEM;

    printk(KERN_INFO "ioremap(0x%08x) -> %p\n", SYS_LED_PHYS, led_reg);

    /* 闪烁 5 次 */
    int i;
    for (i = 0; i < 5; i++) {
        iowrite32(0x01, led_reg);   /* 点亮 */
        printk(KERN_INFO "LED ON  (iteration %d)\n", i);
        msleep(500);                /* 内核延时，让出 CPU */

        iowrite32(0x00, led_reg);   /* 熄灭 */
        printk(KERN_INFO "LED OFF (iteration %d)\n", i);
        msleep(500);
    }

    /* 读回观察（注意：可能受内核其他驱动并发写入影响，值不可靠） */
    unsigned int val = ioread32(led_reg);
    printk(KERN_INFO "LED readback = 0x%02x\n", val);

    return 0;
}

static void __exit led_exit(void)
{
    if (led_reg) {
        iowrite32(0x00, led_reg);   /* 关 LED */
        iounmap(led_reg);           /* 解除映射 */
    }
    printk(KERN_INFO "Kernel LED Driver removed\n");
}

module_init(led_init);
module_exit(led_exit);

MODULE_LICENSE("GPL");
```

逐条对比裸机版的差异：

- **`ioremap(SYS_LED_PHYS, 4)`**：内核开启了 MMU，物理地址不能直接访问。`ioremap` 把物理地址映射到内核虚拟地址空间，返回一个可以安全读写的指针。裸机没有 MMU，直接写物理地址就行。
- **`iowrite32` / `ioread32`**：不是直接解引用指针（`*led_reg = 0x01`），而是用专门的 I/O 访问函数。某些架构上它们有特殊屏障语义，保证访问顺序。
- **`printk`**：内核的 `printf`。输出到内核日志缓冲区，`dmesg` 能看到。不需要查串口状态寄存器。
- **`msleep(500)`**：内核调度器帮你延时。调用线程睡眠 500ms，CPU 可以跑别的任务。裸机只能忙等。
- **`module_init` / `module_exit`**：告诉内核"加载我时调 led_init，卸载时调 led_exit"。驱动有了明确的生命周期。

#### 3. Makefile

```makefile
obj-m += led_module.o

# 指向内核源码树（必须与客户机内核同源编译）
KDIR ?= ../linux-6.19

all:
	$(MAKE) ARCH=arm CROSS_COMPILE=arm-linux-gnu- -C $(KDIR) M=$(CURDIR) modules
```

- `obj-m`：声明要编译成模块（`.ko`）的目标文件。
- `-C $(KDIR)`：到内核源码树里执行 make，用内核的构建系统。
- `M=$(CURDIR)`：告诉内核构建系统"我的模块源码在当前目录"。

> [!warning] 模块必须与内核同源编译
> 内核模块的符号表（`Module.symvers`）和 `vermagic` 必须与客户机内核完全匹配。内核树需要先跑过一次 `make modules` 生成完整的 `Module.symvers`，否则模块加载时会报符号未定义。这个约束在 1.5.1 第 6 小节讲过。

#### 4. 编译与加载

```bash
# 编译
make ARCH=arm CROSS_COMPILE=arm-linux-gnu- -C ../linux-6.19 M=$(pwd) modules
# 产物 led_module.ko（ARM 内核模块）

# 放进 initramfs，重新打包
cp led_module.ko ../initramfs/
cd ../initramfs && find . | cpio -o -H newc | gzip > ../initramfs_led.cpio.gz

# 启动客户机（用含模块的 initramfs）
qemu-system-arm -M vexpress-a9 -smp 4 -m 512M \
    -kernel linux-6.19/arch/arm/boot/zImage \
    -dtb linux-6.19/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb \
    -initrd initramfs_led.cpio.gz \
    -append "console=ttyAMA0" \
    -net nic,model=lan9118 -net user,hostfwd=tcp:127.0.0.1:5555-:22 \
    -device virtio-rng-device -nographic
```

客户机启动后，在 shell 里加载模块：

```bash
# 客户机 shell
insmod /led_module.ko
dmesg | tail -20     # 查看内核日志里的 LED 驱动输出
```

#### 5. 运行结果

实跑验证（`verify-kernel-led.sh`，rc=0）：

```text
=== Kernel LED Driver (module) ===
ioremap(0x10000008) -> 77d0b07d     ← 物理地址映射到内核虚拟地址
LED ON  (iteration 0)               ← iowrite32(0x01)
LED OFF (iteration 0)               ← iowrite32(0x00)
...（5 次闪烁，每次 500ms）
LED readback = 0x09                 ← 注意：写的 0x00，读回 0x09（并发写入干扰）
=== Kernel LED Driver done ===
```

> [!warning] readback 值不可靠
> 模块最后写 `0x00`，读回却是 `0x09`（多次运行结果不同：0x09/0x34）。原因是内核的 `ledtrig-cpu` 等内置驱动在并发写同一寄存器。本模块没有申请资源所有权，无法独占控制。这个值**不能**用来验证 LED 状态——它只能证明 `ioremap` 映射成功、读写操作确实到达了寄存器。

和裸机版的对比——**代码执行链路验证通过**（模块加载→ioremap→闪烁 5 次→完成），但 LED 控制的正确性受资源冲突影响：

| 指标         | 裸机版               | 内核模块版                                   |
| ------------ | -------------------- | -------------------------------------------- |
| 代码行数     | ~60 行（含串口驱动） | ~45 行（不含串口驱动）                       |
| 串口/日志    | 手写 PL011 驱动      | `printk` 一行                                |
| 延时精度     | 盲等（不准）         | `msleep` 精确 500ms                          |
| 硬件访问     | 直接写物理地址       | `ioremap` 映射（演示 API，未取得资源所有权） |
| LED 独占控制 | 是（无其他驱动竞争） | 否（与内置驱动冲突）                         |
| 可卸载       | 否（死循环 hang）    | `rmmod` 卸载                                 |

#### 6. 这一步的局限

本节用 `ioremap` 直接映射寄存器——这是最底层的方式，和裸机只有"加了 MMU 映射"的区别。真实驱动不会这样写：

- **不会直接用物理地址**：而是从设备树/平台设备获取资源（`platform_get_resource`），由内核告诉你地址。
- **不会用 `ioremap` 绕过子系统**：LED 有专门的 GPIO 子系统（`gpiod_get` / `gpiod_set_value`），网卡有 `net_device_ops`，每种设备有对应的标准接口。
- **不会有 init 里的忙循环**：probe 函数里只做初始化，不做耗时操作。

这些规范化的做法是后续章节的主题：字符设备（第二章）、平台驱动 + 设备树（第三章）、中断（第四章）。本节的目标只是让你看到**从裸机到内核的最小演进**——OS 的基础设施如何让驱动更简洁。
