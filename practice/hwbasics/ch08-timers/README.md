# ch08-timers — 定时器：SysTick 深入 + CMSDK 双定时器双时基

《嵌入式硬件基础》系列（ch08）实验工程，基于
`ch04-baremetal-template` 底座（启动文件/链接脚本同源，仅向量表为
CMSDK 定时器开出了具名 IRQ 槽位）。

对应文章：`content/2026-08-30-embedded-basics-ch08-timer-systick.md`

## 文件清单

| 文件            | 职责                                                              |
| --------------- | ----------------------------------------------------------------- |
| `startup.S`     | 启动文件（同 ch04 + IRQ8/9/10 具名向量：Timer0/1/DualTimer）      |
| `mps2_an385.ld` | 链接脚本（与 ch04 模板逐字一致）                                  |
| `main.c`        | 两个实验：SysTick 轮询/中断双模式 + 双时基并行                    |
| `Makefile`      | `make` / `make run` / `make capture` / `make disasm` / `make gdb` |

## 环境

- `arm-none-eabi-gcc` 15.2.0（测试版本）
- `qemu-system-arm` 10.1.5（测试版本）
- 机型 `-M mps2-an385`（Cortex-M3）

## 用法

```bash
make            # 编译 + 链接 + size
make run        # 交互运行（Ctrl-A X 退出），实验全程约 8~12 秒
make capture    # timeout 15 批量运行，输出落 build/run.log
make disasm     # 反汇编（看向量表槽 15/26 与 delay_us）
```

程序打印完 `summary:` 后静默 `wfi`（两个时基仍在跑但不再刷屏），
`timeout` 杀掉 QEMU 属预期。

## mps2-an385 定时器资源考证（QEMU v10.1.5 源码）

| 资源                         | 地址/时钟                    | IRQ | 出处                                        |
| ---------------------------- | ---------------------------- | --- | ------------------------------------------- |
| SysTick（核内）              | 0xE000E010..，cpuclk=25MHz   | -15 | ARMv7-M PPB；armv7m cpuclk                  |
| SysTick 参考时钟             | refclk = 1MHz（CLKSOURCE=0） | —   | mps2.c REFCLK_FRQ                           |
| CMSDK APB Timer0             | 0x40000000                   | 8   | mps2.c（base=0x40000000+i·0x1000, irq=8+i） |
| CMSDK APB Timer1             | 0x40001000                   | 9   | 同上                                        |
| CMSDK APB DualTimer（SST-2） | 0x40002000，TIMCLK=25MHz     | 10  | mps2.c 固定映射                             |
| CMSDK APB Watchdog           | 0x40008000                   | NMI | mps2.c                                      |

DualTimer 寄存器布局（`hw/timer/cmsdk-apb-dualtimer.c`，Timer1 偏移
0x00，Timer2 加 0x20）：`LOAD +0x00`（向下重装值）、`VALUE +0x04`
（当前值）、`CONTROL +0x08`、`INTCLR +0x0C`（写任意值清中断）、
`RIS +0x10`（裸状态）、`MIS +0x14`（INTEN 掩码后状态）、`BGLOAD
+0x18`。CONTROL 位：ONESHOT(0)、SIZE(1)=32 位、PRESCALE(2..3)=÷1/16/256、
INTEN(5)、MODE(6)=周期、ENABLE(7)。计到 0 置 intstatus 并拉中断线，
**必须写 INTCLR 才撤**；周期模式自动从 LOAD 重装。

## 实验一要点（SysTick 深入）

- 轮询模式：`CSR = ENABLE|CLKSOURCE`（TICKINT=0），完全不经过 NVIC；
  COUNTFLAG（bit16）在计数器数到 0 时置位，**读 CSR 即清零**；
- `delay_us` 的三个坑与对策：
  1. CVR 回绕是 `0 -> RELOAD`（不是 0xFFFFFF），朴素减法会溢出；
  2. 等待窗宽度 = 周期 − chunk，chunk 逼近整周期时窗口窄到一拍，
     轮询粒度粗就整窗跳过——单段等待压到 ≤ 半周期（反汇编可见
     `movw r4, #12500`）；
  3. 读 CVR 测时长有"同值二义"（差 1 拍还是差 1 个周期？），要请
     COUNTFLAG（电平保持）作证消歧。

## 实验二要点（双时基并行）

- SysTick 切中断模式 1kHz（RTOS tick 姿势）维护 `g_ms` 毫秒计数；
- CMSDK DualTimer Timer1：`LOAD=25,000,000`（TIMCLK 25MHz → 1Hz）、
  `CONTROL=0xE2`（EN|PERIODIC|SIZE32|INTEN）、NVIC `ISER0 |= 1<<10`；
- 主循环每 250ms 打印 DualTimer 倒计数值，1Hz 中断独立打点——
  两路心跳时间戳交错，可见：频率严格同源（同一个 25MHz），
  相位差恒定（dualtimer 先启动约 1ms，是三行 banner 打印的功夫）。

## 预期输出（真实运行，`make capture`）

```text
== ch08 exp1: SysTick polling (TICKINT=0) ==
CSR   = 0x00000005 (ENABLE|CLKSOURCE, TICKINT=0)
CALIB = 0x0000270f (TENMS=9999: 10ms @ 1MHz refclk, no SKEW/NOREF)
poll 5 x 200ms by COUNTFLAG:
  t=200ms t=400ms t=600ms t=800ms t=1000ms
  flags read = 1000 (expect 1000)
COUNTFLAG read-clear: first=0x00010000, immediate re-read=0x00000000
delay_us(1) = 434 ticks (ideal 25)
delay_us(100) = 2610 ticks (ideal 2500)
delay_us(999) = 25104 ticks (ideal 24975)
1000 x delay_us(1000): flags=1000 (expect ~1000)

== ch08 exp2: dual timebase ==
SysTick: 1kHz irq-mode tick (RTOS style), g_ms heartbeat
dualtimer: LOAD=25000000, CTRL=0xE2 (EN|PERIODIC|32B|INTEN)
every 250ms main prints dt VALUE; every 1s irq prints line
[systick ms=250] dt.VALUE=18742311
[systick ms=500] dt.VALUE=12492648
[systick ms=750] dt.VALUE=6243246
[dt irq 1 @ ms=999] VALUE=24995960 RIS=1 MIS=1 -> after-clear MIS=0
[systick ms=1000] dt.VALUE=24989755
[systick ms=1250] dt.VALUE=18743418
[systick ms=1500] dt.VALUE=12493145
[systick ms=1750] dt.VALUE=6241898
[dt irq 2 @ ms=1999] VALUE=24995641
[systick ms=2000] dt.VALUE=24992035
[systick ms=2500] dt.VALUE=12494221
[systick ms=2750] dt.VALUE=6243544
[dt irq 3 @ ms=2999] VALUE=24999373
[systick ms=3000] dt.VALUE=24994071
[systick ms=3750] dt.VALUE=6238106
[dt irq 4 @ ms=3998] VALUE=24998974
[systick ms=4250] dt.VALUE=18717848
[systick ms=4500] dt.VALUE=12466641
[systick ms=4750] dt.VALUE=6217509
[dt irq 5 @ ms=4998] VALUE=24999148
summary: 5 dt irqs, ms(first)=999 ms(last)=4998 -> period=999ms (expect 1000)
[dt irq 6 @ ms=5999] VALUE=24986444
[dt irq 7 @ ms=6998] VALUE=24999192
```

（节选；summary 之后程序静默运行，timeout 到期收尾。）
`period=999ms` 是整数截断：真实平均 (4998−999)/4 = 999.75ms，误差
来自 g_ms 以 1kHz 中断为粒度采样中断时刻。连续 irq 时间戳的差
999/1000/1000/1000/1001/999… 平均恰为 1000——两个时基同源自 25MHz，
只有相位差、没有频率漂移。

## QEMU 边界

- TCG 下 MMIO 轮询一次的代价比真机高一个数量级（微秒级），所以
  `delay_us(1)` 实测 overhead ~400 拍；真机 84MHz 直排循环约 20~30 拍。
- dt 中断响应延迟（重装到 handler 读 VALUE）实测几百 µs（QEMU 主循环
  粒度），真机为异常入口 12 周期 + 流水线冲刷，亚微秒量级。
- 构建产物 `build/` 已被仓库 `.gitignore`（`practice/*/build*/`）排除。
