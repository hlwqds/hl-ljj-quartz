# ch04-baremetal-template — Cortex-M3 裸机最小模板

《嵌入式硬件基础》系列（ch04）的技术底座工程：一个**零依赖**的 QEMU 裸机模板，
含自写启动文件、链接脚本与构建系统。后续章节（ch05 GPIO、ch07 中断、ch08 定时器）
都在本模板上叠加外设代码，不再重写启动链。

对应文章：`content/2026-08-30-embedded-basics-ch04-baremetal-boot.md`

## 文件清单

| 文件             | 职责                                                             |
| ---------------- | ---------------------------------------------------------------- |
| `startup.S`      | 启动文件：向量表（.isr_vector）+ Reset_Handler + Default_Handler |
| `mps2_an385.ld`  | 链接脚本：MEMORY（FLASH/RAM）+ SECTIONS + `_sidata` 等布局符号   |
| `main.c`         | 裸机 main：直写 CMSDK APB UART0 寄存器打印                       |
| `Makefile`       | 一条 make 完成编译链接（产物在 `build/`）                        |
| `CMakeLists.txt` | CMake 等价构建（与 Makefile 二选一）                             |

## 环境

- `arm-none-eabi-gcc`（测试版本 15.2.0）
- `qemu-system-arm`（测试版本 10.1.5）
- 机型 `-M mps2-an385`（Cortex-M3，AN385 FPGA image）

## 用法

```bash
# 方式一：Makefile
make            # 编译 + 链接 + arm-none-eabi-size
make run        # QEMU 运行，串口接终端（退出：Ctrl-A 然后 X）
make disasm     # 反汇编摘录
make gdb        # QEMU 起 gdbserver（-S -s），另开终端 arm gdb 连 :1234
make clean

# 方式二：CMake
cmake -B build -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_SYSTEM_PROCESSOR=arm \
      -DCMAKE_C_COMPILER=arm-none-eabi-gcc \
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
cmake --build build
qemu-system-arm -M mps2-an385 -kernel build/ch04-baremetal.elf -nographic
```

无需交互的批量运行（CI/记录输出）：

```bash
timeout 3 qemu-system-arm -M mps2-an385 -kernel build/ch04-baremetal.elf \
  -display none -serial stdio
```

## 预期输出（真实运行结果）

```text
hello baremetal
text  : FLASH 0x00000000 .. _etext 0x00000368
.data : copy 0x00000368 (LMA in FLASH) -> 0x20000000 (VMA in RAM)
.bss  : zero 0x20000004 .. 0x20000008
data_var @ 0x20000000 = 0x20260830 (reset copy OK)
bss_var  @ 0x20000004 = 0x00000000 (zero OK)
stack  : MSP top 0x20020000
```

程序打印完进入 `wfi` 死循环，`timeout` 到期杀掉 QEMU 属预期行为。

## mps2-an385 关键地址（依据 QEMU v10.1 源码）

| 资源                             | 地址                                        | 出处                            |
| -------------------------------- | ------------------------------------------- | ------------------------------- |
| 代码区（ZBT SSRAM1，角色=FLASH） | 0x00000000，4MB                             | `hw/arm/mps2.c` FPGA_AN385 分支 |
| 数据 RAM（ZBT SSRAM2&3）         | 0x20000000，4MB                             | 同上                            |
| UART0（CMSDK APB UART）          | 0x40004000                                  | `hw/arm/mps2.c` uartbase[]      |
| UART1/2/3/4                      | 0x40005000/0x40006000/0x40007000/0x40009000 | 同上                            |
| DualTimer / WDT / SCC            | 0x40002000 / 0x40008000 / 0x4002f000        | 同上                            |
| SYSCLK / REFCLK                  | 25 MHz / 1 MHz                              | `hw/arm/mps2.c` SYSCLK_FRQ 等   |

UART 寄存器（`hw/char/cmsdk-apb-uart.c`）：DATA +0x00 / STATE +0x04 /
CTRL +0x08 / INTSTATUS +0x0c / BAUDDIV +0x10；模型固定 8N1，
`BAUDDIV = pclk / baud`，QEMU 要求 `16 <= BAUDDIV <= pclk`。

## 作为模板复用

- 新增外设：在 `main.c` 加寄存器宏即可（本模板不引 CMSIS 头，保持 0 依赖）。
- 启用中断：向量表已含 16 个系统异常槽 + 32 个 IRQ 槽，写一个同名强符号
  （如 `void SysTick_Handler(void)`）即可覆盖 `Default_Handler` 弱符号。
- 换到真机 STM32F407：改 `MEMORY` 里的起址/长度（FLASH 0x08000000、
  RAM 0x20000000），换启动文件中与板相关的外设初始化；启动链逻辑不变。

## 注意（QEMU 边界）

- mps2-an385 的 0x0 区在硬件上是 ZBT SSRAM（可写 RAM），不是真 flash；
  QEMU 的 ELF 加载器按 `p_paddr`（LMA）把 .data 初值放到 0x368，Reset_Handler
  再拷贝到 RAM——与真机"flash 保存初值 + 启动代码搬运"行为一致。
- 构建产物 `build/` 已被仓库 `.gitignore`（`practice/*/build*/`）排除，勿提交。
