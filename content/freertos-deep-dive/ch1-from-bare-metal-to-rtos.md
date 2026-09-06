---
title: "FreeRTOS 深度解析（一）：从裸机到 RTOS"
date: 2026-08-26
description: "从裸机超级循环的复杂度爆炸出发，理解 RTOS 调度抽象为什么诞生；认识 Vanilla FreeRTOS 与 ESP-IDF fork 的关系；搭好 ESP32 + QEMU 实验环境并跑起第一个双任务程序；拿到内核源码地图。"
tags: [freertos, rtos, esp32, esp-idf, qemu, xtensa]
---

> [!info] FreeRTOS 深度解析系列 0. [[freertos-deep-dive|系列索引]]
>
> 1. **第一章：从裸机到 RTOS**

# FreeRTOS 深度解析（一）：从裸机到 RTOS

这一章回答三个问题：**为什么需要 RTOS**（裸机到底哪里不够用）、**FreeRTOS 是什么**（它和 ESP-IDF 里的那份是什么关系）、**怎么开始**（环境搭建、第一个程序、源码地图）。读完它，你应该能跑起一个双任务并发的程序，并且知道后面二十几章要读的源码住在文件系统的哪个角落。

---

## 1.1 裸机的极限：为什么需要调度器

RTOS 不是凭空发明的需求。要看清它解决什么问题，最直接的方式是回到没有它的世界，看复杂度是怎么一步步失控的。

### 1. 一件事的程序：超级循环

嵌入式入门程序几乎都是同一个形状——超级循环（super loop）：

```c
int main(void)
{
    system_init();
    while (1) {
        read_sensor();
        process_data();
        update_display();
    }
}
```

只有一件事要做时，这是最完美的结构：简单、确定、零开销。CPU 依次执行每个步骤，周而复始。

但"一件事"的程序在真实产品里几乎不存在。麻烦从第二件事开始。

### 2. 第二件事进来：周期冲突

假设现在要同时做两件事：

- 任务 A：每 10ms 读一次传感器并处理；
- 任务 B：每 500ms 刷一次屏幕（刷屏耗时 50ms）。

超级循环没有"每 10ms"的概念，只能手动拼：

```c
while (1) {
    if (tick_10ms_elapsed()) {
        read_sensor();
        process_data();
    }
    if (tick_500ms_elapsed()) {
        refresh_display();   /* 耗时 50ms —— 问题在这里 */
    }
}
```

问题立刻出现：`refresh_display()` 执行的 50ms 里，传感器读不了。任务 A 的"每 10ms"被破坏了。而且这不是 bug，是**结构性的**——顺序执行的代码里，长操作必然挡住短周期。

常见的缓解是"打碎"：把 `refresh_display()` 拆成 100 个每次 0.5ms 的小步骤，在循环里每次只走一步：

```c
while (1) {
    if (tick_10ms_elapsed()) { read_sensor(); process_data(); }
    display_step_once();     /* 每轮只推进 0.5ms 的绘制 */
}
```

能用，但代价是：**业务逻辑（怎么刷屏）和调度逻辑（什么时候刷多少）搅在了一起**。刷屏代码不再按"刷一块屏"思考，而要按"切成 100 步、每步可重入"思考。

### 3. 等待外设：空转的 CPU

再进一步。传感器是 I2C 的，读一次要 2ms；Flash 写一页要 3ms；每个等待都让 CPU 在空转：

```c
/* I2C 读：发起 -> 等从机 -> 收数据 */
i2c_start(addr);
while (!(I2C_SR & I2C_RXNE))    /* 空转等硬件 */
    ;
data = I2C_DR;
```

单任务时无所谓——CPU 反正没别的事干。多任务时这是暴殄天物：任务 B 等 Flash 的 3ms 里，任务 A 本可以跑 300 个 10ms 周期里的一整个。

于是又要手搓"非阻塞状态机"：发起 I2C 读写就返回，主循环轮询标志位，完成了再处理。每个外设交互都要拆成"发起/检查/收尾"三段。

### 4. 中断登场：前后台系统

引入中断后，程序演变成经典的**前后台系统**（foreground/background）：中断是前台，主循环是后台。

```c
volatile bool rx_done;
volatile uint8_t rx_buf[64];

void USART1_IRQHandler(void)     /* 前台：中断，快进快出 */
{
    if (rx_done) { /* overrun! */ }
    rx_buf[get_index++] = DR;
    if (buffer_full())
        rx_done = true;
}

int main(void)                    /* 后台：主循环轮询标志 */
{
    while (1) {
        if (rx_done) {
            process_packet(rx_buf);
            rx_done = false;
        }
        /* ...其余所有功能，同样以标志位轮询... */
    }
}
```

前后台系统能撑起相当复杂的产品，但它有三个抹不掉的痛点：

| 痛点                   | 表现                                                                  |
| ---------------------- | --------------------------------------------------------------------- |
| 等待仍然占着执行流     | 后台代码里所有耗时操作还是要手搓状态机拆碎（见第 2 小节）             |
| 共享数据靠人肉纪律保护 | 前后台都要碰的变量，必须记得加 `volatile`、关中断——忘一处就是偶发 bug |
| 优先级是隐式的、僵化的 | 谁先被轮到谁先跑；想临时让某个处理"插队"，要重构整个循环顺序          |

第三点最致命。产品迭代到后期，"按键响应必须在 5ms 内"这种需求一出现，工程师发现要动的不是按键代码，而是整个主循环的排列组合。

### 5. 问题的本质：等待与执行流绑死了

把上面所有痛点收拢成一句话：

> **在裸机模型里，"一个执行流"与"一件工作"是绑死的。等待某件事时，执行流也跟着停摆——尽管 CPU 明明可以去干别的。**

所有手搓技巧——标志位、状态机、操作打碎——本质上都是在用**应用代码模拟调度**：手动决定"现在这一刻 CPU 该推进哪件事"。模拟出来的调度器散落在每个模块里，无法审计、无法复用、改一处动全身。

### 6. RTOS 的回答：把调度下沉给内核

RTOS 的思路是把这个模拟了千百遍的东西正式抽象出来，做成一个**独立的、通用的调度器**：

```text
   裸机：执行流 == 工作            RTOS：执行流 == 任务，由内核统一调度
   ─────────────────────           ─────────────────────────────────
   while (1) {                     task_sensor() { for(;;) {
     工作 A 的一个碎片                读传感器;
     工作 B 的一个碎片                vTaskDelay(10ms);   ← 等待交给内核
     工作 C 的一个碎片              } }
     ...                          task_display() { for(;;) {
   }                                  刷一整块屏;          ← 不用再打碎!
                                      vTaskDelay(500ms);
                                   } }
                                  内核: 谁就绪谁上CPU，谁在等就挂起谁
```

关键变化有三层：

1. **每件工作有自己的执行流（任务）**，写成直观的顺序代码，`vTaskDelay()`（或等队列、等信号量）就阻塞，CPU 自动让给别人。第 2 小节里"刷屏 50ms 挡住传感器"的问题消失了——不是被解决了，是**不再存在**：两个任务各有各的执行流。
2. **等待变成一等公民**。延时、等数据、等事件，统一抽象成"阻塞"，由内核记账（超时、唤醒、排序），应用代码里不再有手搓状态机。
3. **优先级显式化**。每个任务创建时带优先级，调度器保证"最高优先级的就绪任务永远在跑"。按键要 5ms 响应？给它高优先级即可，不用重排主循环。

代价也是明确的：内核本身要占几 KB 到十几 KB Flash/RAM、每个任务要独立栈、上下文切换有微秒级开销、以及——共享数据的保护从"人肉纪律"升级成"必须理解的新规则"（这是 Part III 的主题）。所以裸机并非"落后"，而是需求没到；一旦多任务 + 多周期 + 响应时间约束叠加，RTOS 的抽象就开始回本。

> [!note] 一句话版本
> 裸机的根本约束是"等待占住执行流"；RTOS 的全部意义，是把"谁在等、谁该跑"这件事从应用代码里抽出来，交给一个专门的、可审计的调度器。

---

## 1.2 FreeRTOS 是什么：内核、生态与 ESP-IDF fork

有了"要一个调度器"的需求，看 FreeRTOS 在解决方案光谱里的位置。

### 1. 系统形态光谱

从裸机到通用操作系统，嵌入式软件形态大致是这样一个谱系：

```text
  裸机/前后台          RTOS                    通用 OS (Linux)
  ───────────   ──────────────────────   ─────────────────────
  主循环+中断     调度器+内核对象           进程/虚拟内存/系统调用
  无任务概念      任务有栈、无地址空间隔离    进程有地址空间隔离
  手搓状态机      优先级抢占调度             公平+CFS等复杂调度
  RAM 需求最小    内核 ~10KB 级              内核 MB 级
  确定性最好      确定性好(可分析)            确定性差(默认配置)
  适用: 单一功能   适用: 多任务+实时约束       适用: 复杂应用+生态
```

RTOS 卡在中间：比裸机多了调度器和同步原语，但**没有**进程隔离、虚拟内存、用户态/内核态这些重型机制。FreeRTOS 的任务（task）更接近"线程"：所有任务共享同一地址空间，直接互相调用变量——快，但纪律靠自己（和内核对象）保证。

### 2. 实时性指什么

"实时"（real-time）常被误解成"快"。准确含义是**确定性**（determinism）：

| 术语   | 含义                                       | 例子           |
| ------ | ------------------------------------------ | -------------- |
| 硬实时 | 错过截止时间的后果是灾难，必须可证明地满足 | 安全气囊控制器 |
| 软实时 | 偶尔错过可接受，统计上满足即可             | 视频播放       |
| 非实时 | 无截止时间承诺                             | 网页服务器     |

FreeRTOS 是**硬实时友好**的内核：固定优先级抢占调度，最高优先级就绪任务被唤醒到上 CPU 的路径短而确定（第 6、7 章会精确到指令级）。但注意——用上 FreeRTOS 不等于系统就是实时的：某个任务里一句 `printf` 占住 CPU 不放，所有比它低优先级的任务照样饿死。实时性是设计出来的，内核只是提供了不挡路的机制。

### 3. FreeRTOS 内核有多小

FreeRTOS 的"内核"指六个 C 文件加一套头文件：

| 文件              | 职责                                   | 默认树中的体量（IDF v6.0.2） |
| ----------------- | -------------------------------------- | ---------------------------- |
| `tasks.c`         | 任务管理 + 调度器 + Idle 任务          | ~273 KB 源码，全内核心脏     |
| `queue.c`         | 队列 + 信号量 + 互斥量（一个文件全包） | ~140 KB                      |
| `stream_buffer.c` | 流缓冲 / 消息缓冲                      | ~66 KB                       |
| `timers.c`        | 软件定时器（守护任务模型）             | ~54 KB                       |
| `event_groups.c`  | 事件组                                 | ~35 KB                       |
| `list.c`          | 内核链表原语（一切数据结构的地基）     | ~10 KB                       |

体量说明两件事：一，这不是一个能"顺带读完"的内核，但也不是读不完——本系列 Part II~III 就是按这个文件清单推进的；二，`queue.c` 一个文件装下队列、信号量、互斥量三样东西，暗示了它们的同源本质（第 10、11 章展开）。

除内核文件外，每个 CPU 架构还需要一个**端口层**（port）：`port.c` + `portmacro.h` + 若干汇编，负责上下文切换、临界区、tick 这些必须贴着硬件做的事（Part IV 主题）。

### 4. Vanilla FreeRTOS：上游是什么

**Vanilla FreeRTOS**（官方文档自己的称呼，本文沿用）指 FreeRTOS.org 维护的上游内核。它的一些基本事实：

- 内核采用 MIT 许可，2003 年由 Richard Barry 创建，现由 AWS 维护（这也是它生态强大的原因之一）；
- 设计目标是**单核 MCU**：整个内核的全局状态（当前任务、就绪链表、tick 计数）都按"只有一个 CPU"组织，临界区靠关中断保护——这个假设是理解后面 SMP 改造难度的前提；
- 移植覆盖 40+ 架构（ARM Cortex-M、RISC-V、Xtensa、AVR、MIPS……），官方口号级别的数字：内核核心约 6000~9000 行 C；
- 支持协程（co-routine，现已边缘化）和抢占式任务两种模型，现代用法几乎全是后者。

### 5. ESP-IDF fork：IDF FreeRTOS

写 ESP32 程序时，你用的 FreeRTOS **不是**从 FreeRTOS.org 下载的那份，而是 ESP-IDF 里的一个深度改造 fork，官方文档称为 **IDF FreeRTOS**。三件事实需要现在就建立认知：

**事实一：基线是 Vanilla v10.5.1。** IDF FreeRTOS 基于 Vanilla FreeRTOS v10.5.1 修改而来，API 面基本一致——你在 FreeRTOS 官方教材里学到的 `xTaskCreate`、`xQueueSend` 在 ESP32 上都原样可用。

**事实二：改造的动机是双核。** ESP32 是双核 SMP SoC（两个对等的 Xtensa LX6 核，共享内存），而 Vanilla 内核按单核假设写就。Espressif 为此重写了内核的关键路径：调度器按"每核独立选任务"组织、临界区从关中断升级为自旋锁、增加了核亲和（core affinity）概念和 `xTaskCreatePinnedToCore()` API 族、每个核一个独立 Idle 任务。这些差异小到 API 签名，大到调度语义（例如同优先级时间片从完美 Round-Robin 退化为 Best-Effort Round-Robin）。

**事实三：源码上是两棵树。** 在 ESP-IDF v6 的 `components/freertos/` 下并存两份独立的源码树：`FreeRTOS-Kernel/` 是 **IDF FreeRTOS 本体**（就是上面说的那个 SMP 改造 fork，v6 默认编入固件的就是它）；`FreeRTOS-Kernel-SMP/` 名字容易误导——它其实是上游官方新做的 Amazon SMP 内核（v11 基线），作为实验选项由 `CONFIG_FREERTOS_SMP` 开关引入。1.6 节会带你看实地的目录，第四章会把"谁是默认、怎么选"用构建脚本一锤定音。

> [!tip] Vanilla vs ESP-IDF：本系列的暗线
> 从本章起，每个机制都会尽量给一次对照。已经出现的两例：
>
> | 主题       | Vanilla FreeRTOS                           | IDF FreeRTOS                          |
> | ---------- | ------------------------------------------ | ------------------------------------- |
> | 目标硬件   | 单核 MCU                                   | 双核 SMP（ESP32/S3/P4），亦可配成单核 |
> | 任务栈单位 | `xTaskCreate` 的栈深参数以**字**（word）计 | 同一参数以**字节**（byte）计          |
>
> 第二例值得单独强调：在 STM32 教程里写 `xTaskCreate(..., 128, ...)` 表示 128 字（512 字节）栈；把同样代码搬进 ESP-IDF，128 就只代表 128 字节——照抄参数是新手翻车高发点。

### 6. 为什么选它当解剖对象

把 FreeRTOS 选为一个深度解析系列的对象，理由有三：

1. **代码量在甜点区**。比 Zephyr 小一个数量级（Zephyr 是带驱动框架、设备树、网络的完整 OS），又比"玩具调度器"完整——所有 RTOS 该有的部件都在，且每个部件都小到能整体装进脑子。
2. **它是事实标准**。多年位居嵌入式市场占有率第一（VDC、Embedded Market Studies 等调研口径），学它的回报直接体现在招聘需求和存量代码上。
3. **IDF fork 是稀有的 SMP 教材**。"把单核 RTOS 改成双核"是工业界反复出现的需求（AMP/SMP/锁的设计），而 IDF FreeRTOS 是少数**完整、生产级、带文档**的范本。这也是本系列选 ESP32 平台、而不是更主流的 STM32 的核心理由。

---

## 1.3 实验平台：ESP32 与 QEMU

### 1. ESP32 是什么

ESP32（经典版，2016 年发布）是乐鑫（Espressif）的 WiFi+蓝牙 SoC，本系列的默认目标芯片：

| 维度    | 规格                           | 对本系列的意义                    |
| ------- | ------------------------------ | --------------------------------- |
| CPU     | 双核 Xtensa LX6 @ 240MHz       | SMP 主题（Part VI）的硬件前提     |
| ROM/RAM | 448KB ROM / 520KB SRAM         | 内存紧张感真实，Part V 有戏可看   |
| Flash   | 外挂 SPI Flash（4~16MB 典型）  | XIP、内存映射、分区表（第 3 章）  |
| 外设    | UART/SPI/I2C/LEDC/PCNT/RMT/... | 驱动实验素材                      |
| 无线    | WiFi 802.11 b/g/n + BT         | 本系列不涉及，但解释了 SoC 的生态 |

关于 CPU 核的命名有个历史包袱先交代：ESP-IDF 文档里 Core 0 / Core 1 有别称 **PRO_CPU / APP_CPU**（Protocol CPU / Application CPU），反映典型应用的分工——WiFi/BT 协议栈任务钉在 Core 0，应用任务钉在 Core 1。读到这两个词时知道它们就是核编号即可。

### 2. 为什么不是别的平台

| 平台            | 优势                                 | 不选它的原因                                          |
| --------------- | ------------------------------------ | ----------------------------------------------------- |
| STM32 + Vanilla | 最"教科书"，与官方教材一一对应       | 无 SMP 维度；需购硬件才能跟做                         |
| POSIX 模拟器    | 零门槛                               | 无交叉编译、无真实中断/端口层，源码理解的两大支柱缺失 |
| ESP32 + IDF     | 官方 QEMU 仿真、SMP 活教材、生态最大 | 内核是 fork，需对照着读（恰好是本系列暗线）           |

### 3. QEMU：无硬件跟做

Espressif 官方维护一个 QEMU 的 fork，实现了 ESP32（以及 C3/S3/P4 等）的 CPU、内存和主要外设的仿真，并把它接进了 `idf.py`：

```bash
idf.py qemu monitor    # 编译 + 启动 QEMU + 连上串口监视器
idf.py qemu gdb        # 编译 + 启动 QEMU(带 GDB server) + 起 GDB
```

对本系列这意味着：**每一章的实验都不需要买板子**。UART 输出、GDB 断点、寄存器观察全部可用；只有真实的 GPIO 时序、WiFi 射频这类物理量需要真机。两个世界里代码完全一致（同一份二进制，QEMU 只是换了执行者），文中需要区分时会明确标注。

> [!note] 和 Linux Driver 系列是什么关系
> 本仓库另有一个 [[linux-driver-deep-dive|Linux 设备驱动开发详解系列]]，用 QEMU vexpress-a9 讲 Linux 内核态驱动。两个系列共用"QEMU 无硬件"方法论，但研究对象互补：那边是**通用 OS 里的驱动子系统**（有进程、有 VFS、有内存隔离），这边是**RTOS 内核本身如何构造**（无进程、无隔离、调度即一切）。先读哪个都行，交叉概念会互相引用。

---

## 1.4 搭建开发环境

以下全部在 x86_64 Linux 上验证过的路径（Fedora/Ubuntu 皆可）。目标是三样东西：ESP-IDF 工具链、QEMU fork、一个能跑的项目。

### 1. 安装 ESP-IDF v6

ESP-IDF 不装进系统目录，而是克隆一份仓库，用脚本把工具链装到 `~/.espressif/`：

```bash
mkdir -p ~/esp && cd ~/esp
git clone -b v6.0.2 --recursive https://github.com/espressif/esp-idf.git
cd esp-idf
./install.sh esp32        # 只装 esp32 目标的工具链；要全家桶则用 all
```

`--recursive` 必不可少——IDF 的组件（包括 FreeRTOS 内核源码树）都是 git submodule，漏掉它你会得到一个"看起来完整、编译时缺文件"的仓库。

每次打开新终端使用前，把环境变量加载进当前 shell：

```bash
. ~/esp/esp-idf/export.sh
```

（嫌麻烦的话，官方还提供 VS Code 插件和 Windows 安装器，本系列命令行为主。）

### 2. 安装 QEMU fork

预编译二进制通过 IDF 自己的工具脚本安装：

```bash
# 先装系统依赖（Ubuntu/Debian）
sudo apt-get install -y libgcrypt20 libglib2.0-0 libpixman-1-0 libsdl2-2.0-0 libslirp0
# Fedora 对应：sudo dnf install libgcrypt glib2 pixman SDL2 libslirp

python $IDF_PATH/tools/idf_tools.py install qemu-xtensa
. $IDF_PATH/export.sh      # 重新加载，让 qemu 进入 PATH
```

`qemu-xtensa` 是给 ESP32/S3 用的；若还想实验 C3 等 RISC-V 芯片，把参数换成（或加上）`qemu-riscv32`。

### 3. 验证

```bash
idf.py --version          # 应输出 IDF 检测信息与版本
qemu-system-xtensa --version   # Espressif fork 的 QEMU
```

两条都有正常输出，环境就绪。

### 4. 有真实开发板的话

任何 ESP32 DevKitC（或兼容板）都可以并行验证：USB 连接后把命令里的 `qemu` 换成 `flash monitor`：

```bash
idf.py -p /dev/ttyUSB0 flash monitor   # 烧录 + 串口监视
```

程序代码零修改。后文不再区分，统一以 QEMU 输出为准。

---

## 1.5 第一个程序：两个任务的 Hello World

按系列惯例，第一个程序要一次触碰本系列的三个核心名词：任务、优先级、阻塞。

### 1. 创建项目

```bash
cd ~ && idf.py create-project freertos-ch1 && cd freertos-ch1
idf.py set-target esp32
```

生成的骨架是三个文件：顶层 `CMakeLists.txt` + `main/CMakeLists.txt` + `main/<工程名>.c`——注意 v6 的 `create-project` **按工程名命名源文件**（这里是 `freertos-ch1.c`，内含一个空 `app_main`），并不存在 `main/main.c`。把 `main/freertos-ch1.c` 的内容整个替换为下面的代码：

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

/* 任务一：高优先级，200ms 周期 */
static void fast_task(void *arg)
{
    int n = 0;
    for (;;) {
        printf("[fast] tick %d (core %d)\n", n++, xPortGetCoreID());
        vTaskDelay(pdMS_TO_TICKS(200));
    }
}

/* 任务二：低优先级，1000ms 周期 */
static void slow_task(void *arg)
{
    for (;;) {
        printf("[slow] hello from the low priority task\n");
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

void app_main(void)
{
    xTaskCreate(fast_task, "fast", 2048, NULL, 5, NULL);
    xTaskCreate(slow_task, "slow", 2048, NULL, 3, NULL);
    /* app_main 返回后：main 任务被内核删除 —— 细节见第 3 章 */
}
```

### 2. 逐参数读懂 xTaskCreate

```c
BaseType_t xTaskCreate(TaskFunction_t  pvTaskCode,   // 任务函数
                       const char      *pcName,      // 名字（调试用）
                       uint32_t         usStackDepth,// 栈大小
                       void            *pvParameters,// 传给任务函数的参数
                       UBaseType_t     uxPriority,   // 优先级
                       TaskHandle_t   *pxCreatedTask);// 句柄回传（可 NULL）
```

| 参数     | 本例取值    | 要点                                                                                       |
| -------- | ----------- | ------------------------------------------------------------------------------------------ |
| 任务函数 | `fast_task` | 签名固定 `void f(void *)`；**永不返回**，死循环是常态而非坏味道                            |
| 栈大小   | `2048`      | **IDF 中单位是字节**（Vanilla 是字！见 1.2 节暗线表）。2048 是含 printf 的任务的保守起步值 |
| 优先级   | `5` / `3`   | 数值越大越优先；0 保留给 Idle 任务。这里的语义是：fast 就绪时 slow 必须让路                |
| 句柄     | `NULL`      | 之后想 `vTaskDelete()` 它时才需要留句柄                                                    |

两个函数体里的 `vTaskDelay(pdMS_TO_TICKS(200))` 是全程序的关键：它把当前任务挂起 200ms，**期间 CPU 不属于它**。对照 1.1 节的裸机世界——这里没有任何"打碎长操作"的手法，`slow_task` 想干一整件事就干一整件事，因为它的 1000ms 沉睡挡不住任何人。

`xPortGetCoreID()` 是 IDF 扩展 API，返回任务当前所在的核编号。放它是为了一件事：观察**不绑核的任务到底落在哪个核上跑**。先剧透一句诚实的结论：在这个程序里你**看不到**任务「漂移」——两行输出会始终显示 `(core 0)`，为什么、以及怎么让 Core 1 真正出场，见下面第 4 节的第 3 点（这也是 Part VI 的伏笔）。

### 3. 跑起来

```bash
idf.py qemu monitor
```

首次会完整编译（几百个文件的进度条），随后 QEMU 启动、串口监视器接上。典型输出（启动日志因版本而异，截取关键部分）：

```text
I (1604) main_task: Started on CPU0
I (1604) main_task: Calling app_main()
[fast] tick 0 (core 0)
[slow] hello from the low priority task
[fast] tick 1 (core 0)
[fast] tick 2 (core 0)
[fast] tick 3 (core 0)
...
```

（以上为本机 QEMU 实跑截取，启动日志因版本而异；完整运行约 15 秒里 `(core 1)` 一次都没出现——这是真实行为，不是异常，下一节解释。）

退出监视器：`Ctrl-]`（QEMU 随之结束）。

### 4. 观察到什么

从这几行输出能读出的信息，比看起来多：

1. **并发是真的**。`fast` 每 200ms 一行、`slow` 每 1000ms 一行，稳定交错——两个"执行流"在同一个 CPU 时间轴上独立推进。1.1 节里"刷屏挡住传感器"的问题，在这个程序里**结构性地不存在**。
2. **优先级在起作用，但你看不见抢占**。因为两个任务大部分时间都在 `vTaskDelay` 里睡着，醒来的瞬间错开了。想看见抢占，把 `slow_task` 里加一个 `while(1) {}` 的死循环忙等试试——`fast` 依旧准时：tick 中断唤醒它，它优先级更高，立刻抢走 CPU。这个实验留给读者，机制在第 6~8 章拆到指令级。
3. **不绑核 ≠ 会漂移**。`xTaskCreate`（非 PinnedToCore 版本）创建的任务亲和掩码是「两个核都行」，但这只表示**允许**，不表示**必然**。本程序里两个任务几乎全程在 `vTaskDelay` 里睡觉，每次都在 tick 上下文里醒来——而 Core 0 此刻闲着，当场就把就绪任务抢走，任务根本没有理由换核（实测 15 秒 72 次打印全在 Core 0）。**漂移/换核需要竞争条件**。做个一行的对照实验：加一个钉死 Core 0、优先级更高的忙等任务，把 Core 0 变成「忙且不可抢占」，再看输出：

   ```c
   /* 占位任务：忙等，把 Core 0 填满 */
   static void busy_core0(void *arg)
   {
       for (;;) { }
   }

   void app_main(void)
   {
       xTaskCreate(fast_task, "fast", 2048, NULL, 5, NULL);
       xTaskCreate(slow_task, "slow", 2048, NULL, 3, NULL);
       /* 顺序很重要：busy0 优先级最高，必须最后创建——先建它会把还在
          app_main（优先级 1）里的 main 任务永久挤下台，后两行永远执行不到 */
       xTaskCreatePinnedToCore(busy_core0, "busy0", 2048, NULL, 6, NULL, 0);
   }
   ```

   本机 QEMU 实跑（同样约 15 秒）：**前两行落在 Core 0（抢在 busy0 启动之前），之后 115 行全部 `(core 1)`**——Core 0 被 priority 6 的忙等占满，优先级 5 的 `fast` 醒来后只能在 Core 1 上运行。「任务跑到当时有空的那个核」这才是 SMP 调度的真实语义，第 22 章拆机制。

   两个实操坑（都是实测踩过的）：① 忙等会饿死 Core 0 的 Idle 任务、触发任务看门狗复位，需在 `sdkconfig.defaults` 加 `CONFIG_ESP_TASK_WDT_EN=n`；② 即便如此，Core 0 上的高优先级系统任务（如 esp_timer，优先级 22）仍能正常抢占 `busy0`——优先级秩序没有被破坏。

4. **printf 没有把调度搞乱**。UART 速度慢，`printf` 内部有缓冲与锁，但任务优先级结构保证了低优先级的 `slow` 打印再慢也挡不住 `fast`。要是反过来（高优先级任务频繁 printf 低优先级任务的数据），就要小心优先级反转——第 11 章的主题。

### 5. 背后发生了什么（一页全景）

目前只需建立地图，不追求精确——每一格都是后面某章的目录项：

```text
 上电 → ROM bootloader → 二级 bootloader（esp-idf） → app_start 系列 C 初始化
                                                            │
                                  创建 main 任务 ────────────┘
                                                            │
                                  app_main() 在 main 任务里运行
                                                            │
              xTaskCreate(fast_task, ...)   ←── 1. 栈从堆分配（第19/20章）
              xTaskCreate(slow_task, ...)   ←── 2. TCB 初始化（第5章）
                                                            │
              app_main 返回，main 任务自删除   ←──（第3、9章）
                                                            │
              调度器常驻：tick 中断每 1ms 打点（默认 100Hz）（第6、8章）
                  ├─ 有任务该醒 → 移入就绪链表（第6章）
                  ├─ 需要切换 → PendSV 类机制触发上下文切换（第7、17章）
                  └─ 全员沉睡 → Idle 任务接管（第9章）
```

### 6. 常见的第一步翻车点

| 症状                             | 原因                                                                                             |
| -------------------------------- | ------------------------------------------------------------------------------------------------ |
| 编译报错找不到 `freertos/task.h` | 没有先 `. $IDF_PATH/export.sh` 就直接 cmake/make 了                                              |
| 任务跑一遍就 restart             | 任务函数 return 了（或没写 `for(;;)`），走到函数尾等于未定义行为；要退出必须 `vTaskDelete(NULL)` |
| 栈大小给成 128 → 运行崩溃        | Vanilla 习惯：128 字 = 512 字节；IDF 里 128 就只有 128 字节（1.2 节暗线）                        |
| QEMU 起不来                      | 忘装 `qemu-xtensa`，或装完没重新 `export.sh`                                                     |

---

## 1.6 源码地图：内核住在哪

系列后半程的主战场是读源码。先领地图。

### 1. components/freertos/ 顶层

FreeRTOS 在 ESP-IDF 里是一个普通组件，位于 `$IDF_PATH/components/freertos/`。以 v6.0.2 为准的顶层结构：

```text
$IDF_PATH/components/freertos/
├── FreeRTOS-Kernel/          # 内核树 A：IDF FreeRTOS 本体（默认编入这棵）
├── FreeRTOS-Kernel-SMP/      # 内核树 B：实验性上游 Amazon SMP 内核（默认不编）
├── esp_additions/            # IDF 附加 API：xTaskCreatePinnedToCore、
│                             #   xPortGetCoreID 等在这棵子树
├── config/                   # FreeRTOSConfig 相关模板
├── port_common.c             # 各架构共享的端口胶水
├── port_systick.c/.h         # tick 中断的产生与接入（接到 esp_timer）
├── heap_idf.c                # 把内核的 pvPortMalloc 接到 IDF heap 组件
├── app_startup.c             # 启动期与 IDF 的挂接
├── Kconfig                   # menuconfig 里那一堆 FREERTOS_* 选项
├── linker*.lf                # 链接脚本片段（函数进 IRAM 等）
└── CMakeLists.txt            # 按配置挑两棵树之一编入
```

两个立刻值得打开看的文件：`port_systick.c`（你会看到 Vanilla 内核里本该由端口提供的 tick，在 IDF 里被接到了 Kconfig 选定的定时器源）和 `Kconfig`（浏览一遍选项名，对内核的可裁剪面建立印象）。

### 2. 默认内核树里有什么

`FreeRTOS-Kernel/` 下就是 1.2 节那张表里的六个文件，外加 `include/`（全部公共头文件）、`portable/`（各架构端口）和一份值得通读的 `idf_changes.md`——那是 Espressif 自己写的"相对 Vanilla v10.5.1 改了什么"的清单，本系列第 22 章的官方对照材料：

```text
FreeRTOS-Kernel/
├── tasks.c            # 273KB：调度器、任务生命周期、Idle、统计
├── queue.c            # 140KB：队列/信号量/互斥量
├── stream_buffer.c    # 66KB：流缓冲、消息缓冲
├── timers.c           # 54KB：软件定时器
├── event_groups.c     # 35KB：事件组
├── list.c             # 10KB：链表原语（先读它！）
├── include/           # FreeRTOS.h / task.h / queue.h ...
├── portable/          # xtensa、riscv 等端口
└── idf_changes.md     # IDF fork 相对 Vanilla 的改造清单
```

### 3. 文件 → 章节映射

| 源文件                   | 深读章节                                                  |
| ------------------------ | --------------------------------------------------------- |
| `list.c`                 | 第 6 章（它是所有链表操作的唯一底座）                     |
| `tasks.c`                | 第 5~9 章（任务、调度、切换、阻塞）+ 第 22 章（SMP 部分） |
| `queue.c`                | 第 10~11 章（队列与信号量）                               |
| `event_groups.c`         | 第 12 章                                                  |
| `tasks.c` 通知部分       | 第 13 章                                                  |
| `stream_buffer.c`        | 第 14 章                                                  |
| `timers.c`               | 第 15 章                                                  |
| `portable/`（xtensa）    | 第 16~18 章                                               |
| `heap_idf.c` + heap 组件 | 第 19~20 章                                               |

### 4. 怎么跟读

```bash
# 你已经装好的 IDF 就是带完整历史的源码仓库：
cd ~/esp/esp-idf/components/freertos/FreeRTOS-Kernel
wc -l *.c
grep -n "xTaskCreate" tasks.c | head    # 从 API 入口向下追
```

两个习惯建议：一，**永远从公共 API 函数入口往下追**（`xTaskCreate` → `xTaskCreateAffinitySet`... 内部链路），而不是从中间某个函数开始读；二，遇到看不懂的宏（`taskENTER_CRITICAL`、`portYIELD`）先跳过记下来，它们都在 Part IV 的射程里。

---

## 1.7 小结

- 裸机的结构性约束是**等待占住执行流**；所有手搓状态机都是在用应用代码模拟调度。RTOS 把这件事正式抽象出来：任务有自己的栈与执行流，阻塞让 CPU，优先级显式化。
- FreeRTOS 是单核假设下的小而完整内核（六大文件）；ESP32 上的那份是 **IDF FreeRTOS**——以 Vanilla v10.5.1 为基线、为双核 SMP 深度改造的 fork，默认编入 `FreeRTOS-Kernel/`；旁边的 `FreeRTOS-Kernel-SMP/` 是实验性上游新内核。栈单位（字 vs 字节）是撞过一次就忘不了的第一个差异。
- 环境：ESP-IDF v6.x + Espressif QEMU fork，`idf.py qemu monitor` 一条命令跑通，全程无需硬件。
- 第一个程序验证了三件事：并发结构性地成立、优先级保证高优先级任务按时运行、不绑核的任务落在「当时有空的核」上（默认程序里全程 Core 0；把 Core 0 用高优先级忙等占住后，全部输出立刻落到 Core 1）。
- 源码地图已领：`components/freertos/FreeRTOS-Kernel/` 是后半程主战场，`idf_changes.md` 值得先通读一遍。

下一章暂离软件，把 ESP32 的硬件底座补齐：Xtensa LX6 的编程模型（寄存器窗口是它和 ARM 最大的不同）、中断体系、内存映射。Part IV 读上下文切换汇编时，那一章是唯一的入场券。
