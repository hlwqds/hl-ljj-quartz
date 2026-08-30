# 《嵌入式硬件基础》系列 · 写作规格 v2（STM32+GD32 主线，无板先行版）

本文件是该系列全部章节作者（子 agent）的统一契约。动笔前通读。

## 0. 平台铁律（v2 核心变更，违反 = 否决）

- **主线平台：STM32F407VET6（Cortex-M4F）+ GD32VF103（RISC-V RV32IMAC）双架构对照**。
- **ESP32 一律不作为教学主线平台**。唯一允许出现的位置：综合项目章的"WiFi 协处理器"
  选型讨论（作为对照选项提及，不写 ESP 教学代码）。
- 板卡未到位，本章系列分两类：
  - **先行章**：不依赖实体板——理论、协议、工具链、QEMU 仿真代码。全部立即写作。
  - **真机占位章**：核心价值是接线/电气实操——写理论骨架 + 接线图 + 预期现象 +
    `> [!warning] 真机待验证` 标注，篇幅可短（200~300 行），板到后回填实测。

## 1. 系列定位与受众

- 受众：系统/网络背景工程师（已源码级读过 RTOS/网络栈），补"从比特到引脚"的硬件
  手艺。类比优先（逻辑分析仪=tcpdump、NVIC=可编程的中断分发器）。
- 双架构学习法：GD32VF103 是 STM32F103 的寄存器级近似双胞胎，同任务双板重做，
  差异即架构知识（向量表 vs mtvec、NVIC vs ECLIC、PendSV vs machine timer）。
- 与 FreeRTOS/lwIP 系列（软件侧）在综合项目会师。

## 2. 文件与格式约定

- 文章：`content/2026-08-30-embedded-basics-chNN-slug.md`（明日日期，本批统一用）。
- frontmatter：title 中文、date `2026-08-30`、description、tags `[embedded, stm32, riscv, 主题…]`。
- 导航 callout 与系列索引 wikilink（`2026-08-30-embedded-basics-series-index`）。
- 先行章 350~600 行；真机占位章 200~350 行；小节 `## N.x`；末尾小结 + 下一章预告。
- 交付前 `npx prettier <新文件> --write`；禁止 git 操作。

## 3. 验证纪律（无板环境）

1. **STM32 代码验证**：工具链 `arm-none-eabi-gcc 15.2`（已装）。两种层次：
   a. **寄存器级裸机**：工程含启动文件（可自写最小 startup）、链接脚本（自写最小
   ld）、Makefile/CMake——`arm-none-eabi-gcc` 编译 + `qemu-system-arm` 跑
   （`-M mps2-an385` 为 Cortex-M3 通用机型；F407 专有外设 QEMU 不仿真，用
   CMSIS 头文件写但寄存器行为标注 QEMU 边界）；
   b. **QEMU 不仿真的部分**：编译通过即最低验收 + `arm-none-eabi-objdump -d`
   反汇编摘录（向量表/指令序列进文章），标 `> [!warning] 真机待验证`。
2. **GD32/RISC-V 代码验证**：本机暂无 riscv 裸机 gcc——RISC-V 章以架构理论与
   对照分析为主，汇编示例给源码但不要求本机编译，标注工具链安装路径。
3. **openocd 待装**（`dnf install openocd`）：涉及 SWD/JTAG 的章节写真机占位 +
   openocd 配置脚本清单（cfg 文件名如实，行为标待验证）。
4. 严禁编造任何"运行输出"；QEMU 输出必须真实跑出来；真机现象必须标注推断依据
   （datasheet 哪一节/官方文档哪个示例）。
5. 参考资料锚点：ARMv7-M Architecture Reference Manual（向量表/异常模型）、
   ST RM0090（F407 外设寄存器）、STM32F407 datasheet、GD32VF103 用户手册——
   引用要具体（章节号/寄存器名），不要泛泛"见手册"。

## 4. 章节清单 v2（12 章 + 索引，先行/占位混合）

| #   | slug                          | 标题                                        | 类型      | 核心内容                                                               |
| --- | ----------------------------- | ------------------------------------------- | --------- | ---------------------------------------------------------------------- |
| 1   | `ch01-roadmap-and-boards`     | 路线图与三件套选型                          | 先行      | 双架构学习法、购物清单、四阶段路径、ESP32 的协处理器定位               |
| 2   | `ch02-tools-multimeter-la`    | 工具驯化                                    | 先行      | 万用表判读、sigrok/PulseView、UART 波形判读（零硬件自检法）            |
| 3   | `ch03-arm-cortex-m-anatomy`   | Cortex-M 解剖：寄存器组、栈、向量表         | 先行      | MSP/PSP、xPSR、异常入栈顺序、`-M mps2-an385` QEMU 实跑                 |
| 4   | `ch04-baremetal-boot`         | 裸机启动：启动文件、链接脚本、Reset_Handler | 先行      | 自写最小 startup.s/ld/Makefile，编译+QEMU 点亮（QEMU 虚拟屏/UART）     |
| 5   | `ch05-gpio-and-mco`           | GPIO 与时钟树                               | 先行+占位 | RCC 时钟树、GPIO 寄存器（RM0090）、QEMU 编译验证、真机点灯占位         |
| 6   | `ch06-uart-protocol`          | UART：协议、成帧、双板通信设计              | 先行+占位 | 8N1/波特率容差/接线三铁律/成帧协议设计（板间协议完整代码设计）         |
| 7   | `ch07-interrupts-nvic`        | 中断体系：NVIC 与 EXTI                      | 先行      | NVIC 寄存器、优先级分组、EXTI 映射、QEMU 跑 SysTick 中断               |
| 8   | `ch08-timer-systick`          | 定时器：SysTick 到通用定时器                | 先行+占位 | SysTick 源码级（QEMU 实跑 1Hz）、预分频/ARR 计算、PWM 思想             |
| 9   | `ch09-riscv-gd32-contrast`    | RISC-V 侧起点：GD32 与架构对照              | 先行      | RV32IMAC、mtvec/mepc/mcause、ECLIC 概览、与 Cortex-M 六维对照表        |
| 10  | `ch10-i2c-spi-theory`         | I2C/SPI 协议理论                            | 先行+占位 | 时序图、地址/ACK、CPOL/CPHA、选型对照；BME280 首读 datasheet 指南      |
| 11  | `ch11-debug-swd-jtag`         | 调试体系：SWD/JTAG/openocd                  | 占位      | 调试架构、openocd cfg 清单、gdb 远程调试流程（真机待验证为主）         |
| 12  | `ch12-freertos-port-contrast` | FreeRTOS 三架构 port 对照                   | 先行      | PendSV vs Xtensa vs RISC-V port（读者已读 Xtensa，双新 port 对照收官） |

（ch3/4/7/8 的 QEMU 实验是本系列"无板先行"的技术底座——mps2-an385 有 UART/SysTick/
定时器模型，足够跑裸机课程。）

## 5. 命名与互链

- 索引：`2026-08-30-embedded-basics-series-index.md`。
- 互链用完整文件名 wikilink；跨系列引用：FreeRTOS 系列（`2026-08-26-freertos-deep-dive-*`）、
  lwIP 系列（`2026-08-26-lwip-deep-dive-*`）按已有文件名。

## 6. 验收清单

1. 先行章：编译/QEMU 证据真实（无 = 否决）；占位章：接线图+预期现象+依据齐全；
2. 编造输出 = 否决；ESP32 出现在主线教学 = 否决；
3. prettier 过；frontmatter/导航/小结/预告齐全；官方参照锚点具体（RM0090 章节号等）；
4. 章末互链闭合（允许前向引用本批并行章节）。
