# ch05-gpio-clock — GPIO 与时钟树（F407 编译验证 + QEMU 实跑）

《嵌入式硬件基础》系列（ch05）的实证工程，基于
`../ch04-baremetal-template/` 启动链扩展，双目标：

| 目标                 | 源文件        | -mcpu     | 链接脚本        | 运行方式                   |
| -------------------- | ------------- | --------- | --------------- | -------------------------- |
| `ch05-gpio-qemu.elf` | `qemu_main.c` | cortex-m3 | `mps2_an385.ld` | QEMU `-M mps2-an385` 实跑  |
| `ch05-gpio-f407.elf` | `f407_gpio.c` | cortex-m4 | `f407.ld`       | 仅编译验证（QEMU 无 F407） |

对应文章：`content/2026-08-30-embedded-basics-ch05-gpio-and-mco.md`

## 与 ch04 模板的差异

- `startup.S`：去掉文件内固定 `.cpu cortex-m3`，改由命令行 `-mcpu` 传入，
  同一启动文件同时服务 M3（QEMU）与 M4（F407）两个目标；
- `f407.ld`：F407VET6 真机内存映射（FLASH 0x08000000/512K，RAM 0x20000000/128K）；
- `qemu_main.c`：MPS2 FPGAIO（0x40028000）点灯/读键/计数器 + 占位设备探针；
- `f407_gpio.c`：STM32F407 真寄存器（RCC_AHB1ENR/GPIOA 全寄存器族），
  CMSIS 风格结构体与裸地址宏两种写法对照。

## 环境

- `arm-none-eabi-gcc` 15.2.0（Fedora 打包）
- `qemu-system-arm` 10.1.5，机型 `-M mps2-an385`

## 用法

```bash
make            # 构建双目标 + size
make run        # QEMU 运行（Ctrl-A X 退出）
make run-log    # 4s 超时批量取证：串口 + guest_errors/unimp 日志 -> build/run.log
make disasm     # F407 目标反汇编摘录（led_init/led_on）
make clean
```

## 预期输出（真实运行，make run-log）

```text
ch05 gpio on qemu mps2-an385 (fpgaio 0x40028000)
[1] LED0 <- 0x0        readback 0x00000000
[1] LED0 <- 0x1        readback 0x00000001
[2] blink x5 ..... done (final LED0=0x00000000)
[3] BUTTON readback   0x00000000 (QEMU 不仿真按键, 恒 0)
[4] CLK100HZ t0=0x00000022 t1=0x00000025 delta=0x00000003
cmsdk-ahb-gpio: unimplemented device write (size 4, offset 0x000, value 0x0000a55a)
[5] stub 0x40010000 <- 0xa55a readback cmsdk-ahb-gpio: unimplemented device read  (size 4, offset 0x000)
0x00000000 (unimplemented: 吞写返 0)
done
```

（第 5 步两行是 QEMU stderr 日志与串口 stdout 交错的原样记录；CLK100HZ 的
t0/t1/delta 每次运行不同，量级一致。）

## mps2-an385 模型考证结论（QEMU v10.1 源码）

| 资源                         | 地址                                       | 状态                                 |
| ---------------------------- | ------------------------------------------ | ------------------------------------ |
| MPS2 FPGAIO（LED/按键/计数） | `0x40028000`                               | 真模型 `hw/misc/mps2-fpgaio.c`       |
| "cmsdk-ahb-gpio" 0..3        | `0x40010000`..`0x40013000`                 | **占位设备**（create_unimplemented） |
| CMSDK APB UART0..4           | `0x40004000`/`0x40005000`/`0x40006000`/... | 真模型                               |
| F407 的 GPIOA/RCC 地址       | `0x40020000`/`0x40023800`                  | mps2 上分别是 PL022 SPI / 未映射区   |

FPGAIO 寄存器（`hw/misc/mps2-fpgaio.c`）：

| 偏移            | 寄存器                  | 行为                                   |
| --------------- | ----------------------- | -------------------------------------- |
| `+0x00`         | LED0                    | 读写；bit_i = 用户 LED_i（num-leds=2） |
| `+0x04`         | DBGCTRL                 | 写入被 LOG_UNIMP 记录（未实现）        |
| `+0x08`         | BUTTON                  | 只读恒 0（模型不仿真按键）             |
| `+0x10`         | CLK1HZ                  | 只读，1Hz 自由计数器（虚拟时钟驱动）   |
| `+0x14`         | CLK100HZ                | 只读，100Hz 自由计数器                 |
| `+0x18`~`+0x20` | COUNTER/PRESCALE/PSCNTR | 预分频计数器                           |
| `+0x28`         | SWITCH                  | 只读恒 0（has-switches 时）            |
| `+0x4c`         | MISC                    | 读回写入值，控制位未实现               |

注：本机 QEMU 10.1.5 无 `query-leds` QMP 命令（实测 CommandNotFound），
LED 状态以固件读回 LED0 寄存器为证。

## F407 关键地址（RM0090）

- RCC 基址 `0x40023800`；`RCC_AHB1ENR` 偏移 `0x30`（APB2RSTR 与 AHB1ENR
  之间有 **两个** 保留字 0x28/0x2C——结构体映射少写一个，AHB1ENR 就错位到
  0x2C，本章反汇编实证过并修正）
- GPIOA 基址 `0x40020000`：MODER+0x00 / OTYPER+0x04 / OSPEEDR+0x08 /
  PUPDR+0x0C / IDR+0x10 / ODR+0x14 / BSRR+0x18 / LCKR+0x1C / AFR+0x20..24 / BRR+0x28

## 注意

- `build/` 已被仓库 `.gitignore`（`practice/*/build*/`）排除，勿提交。
- F407 目标的硬件行为（点灯/按键）为真机待验证项，见文章 5.7 节。
