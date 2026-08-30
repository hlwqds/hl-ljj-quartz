# ch07-nvic-exti -- Cortex-M3 中断实验（QEMU mps2-an385）

《嵌入式硬件基础（七）：中断体系——NVIC、EXTI 与中断驱动的 UART》配套工程。
底座 = `../ch04-baremetal-template/`（同一份链接脚本与启动骨架，向量表换成具名 IRQ 槽）。

## 文件

| 文件             | 说明                                                                 |
| ---------------- | -------------------------------------------------------------------- |
| `startup.S`      | 向量表带具名 IRQ 槽（IRQ 号考证注释自 QEMU v10.1.5 `hw/arm/mps2.c`） |
| `main.c`         | SysTick 100Hz 心跳 + UART0 RX 中断驱动环形缓冲（两个实验一个映像）   |
| `mps2_an385.ld`  | 与 ch04 相同                                                         |
| `Makefile`       | `make` / `make run-heart` / `make run-rx` / `make gdb`               |
| `CMakeLists.txt` | CMake 等价构建                                                       |

## mps2-an385 IRQ 号考证（QEMU v10.1.5 hw/arm/mps2.c，FPGA_AN385 分支）

| NVIC IRQ | 设备                        | 源码依据                                          |
| -------- | --------------------------- | ------------------------------------------------- |
| 0 / 1    | UART0 RX / TX               | `uartirq[] = {0, 2, 4, 18, 20}`，RX 在前，TX=RX+1 |
| 2 / 3    | UART1 RX / TX               | 同上                                              |
| 4 / 5    | UART2 RX / TX               | 同上                                              |
| 8        | Timer0（0x40000000）        | `irqno = 8 + i`                                   |
| 9        | Timer1（0x40001000）        | 同上                                              |
| 10       | DualTimer（0x40002000）     | 显式 `gpio_in(armv7m, 10)`                        |
| 12       | UART0-2 收发溢出（6 线 OR） | orgate → `gpio_in(armv7m, 12)`                    |
| 13       | LAN9118 以太网              | `mps2tz.c`/mps2.c 同款                            |
| 18 / 19  | UART3 RX / TX               | `uartirq[3] = 18`                                 |
| 20 / 21  | UART4 RX / TX               | `uartirq[4] = 20`                                 |
| —        | Watchdog                    | 接 NMI（不是 IRQ 号）                             |

NVIC 规模：`num-irq = 32`。时钟：SYSCLK 25 MHz（`SYSCLK_FRQ`）、REFCLK 1 MHz
（`REFCLK_FRQ`）。SysTick 在核内，不走 IRQ 号（向量表槽 15，异常号 15）。

## 构建

```bash
make            # 产物 build/ch07-nvic-exti.elf（build/ 已 gitignore）
```

## 实验一：SysTick 心跳（无输入，纯看节拍）

```bash
make run-heart  # = timeout 6 qemu-system-arm -M mps2-an385 -kernel build/ch07-nvic-exti.elf \
                #   -display none -serial stdio < /dev/null
```

预期：每秒一行 `[hb ] tick=N sec=N`，6 秒共 7 行（含启动行）。节拍 100Hz
（`SYST_RVR=249999`，CLKSOURCE=1 → 25MHz 处理器时钟）。

## 实验二：UART RX 中断 + 环形缓冲

```bash
make run-rx     # 启动 2 秒后注入 "nvic alive\r"，3 秒后注入 "irq driven uart\n"
```

预期：注入行被 ISR 收进环形缓冲，主循环按行回显并打印统计
（`[rx ] line done: N bytes, irq=M ...`），心跳持续。

## gdb 复现（NVIC 寄存器 + ISR 现场）

```bash
qemu-system-arm -M mps2-an385 -kernel build/ch07-nvic-exti.elf \
    -display none -serial null -S -gdb tcp::1234 &

# 向量表槽 16/17 = IRQ0/IRQ1；断在 SysTick ISR 后逐个读：
gdb --batch -ex 'set architecture arm' -ex 'file build/ch07-nvic-exti.elf' \
    -ex 'target remote localhost:1234' \
    -ex 'x/2wx 0x40' \
    -ex 'break SysTick_Handler' -ex 'continue' \
    -ex 'info registers pc lr xpsr' \
    -ex 'x/wx 0xE000E100' \
    -ex 'x/2bx 0xE000E400' \
    -ex 'x/wx 0xE000E010' \
    -ex 'disconnect'
# x/2wx 0x40        → 向量表槽 16/17（UART0 RX/TX handler 地址）
# info registers    → xpsr 的 IPSR 字段=15、lr=0xfffffff9（EXC_RETURN）
# x/wx 0xE000E100   → ISER0 = 0x1（IRQ0 已使能）
# x/2bx 0xE000E400  → IPR[0] = 0x20（优先级 2<<4）
# x/wx 0xE000E010   → SYST_CSR = 0x00010007（bit16=COUNTFLAG，读后自清）
```

## 已知坑（文章 7.7 节展开）

UART RX ISR 里 **先 W1C 清 `INTSTATUS.RX`、再读 `DATA`**。顺序反了会丢字节通知：
读 DATA 触发模型立刻送来下一个字节并重新置位挂起标志，随后的 W1C 把它误清，
该字节永远无人通知（现象：只回显第一个字符）。
