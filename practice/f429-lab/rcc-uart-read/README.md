# rcc-uart-read —— RCC 三连读取器（固件版）

把 [[ch00e-clock-tree-and-systick-silicon|时钟树章]] 的 `mdw 0x40023800 3` 验尸术写成
固件：**先读时钟树算出真实 PCLK2 → 按它配 USART1 波特率 → 逐位解码打印三寄存器**。
不改任何时钟配置，读到什么打什么——上电 HSI 默认态、clock_init 后的 180MHz 态都能
正确打印（波特率随树自适应，这正是"三连"精神的代码版）。

## 结构

- `startup.S` 最小启动（向量表 + .data/.bss 初始化，无库依赖）
- `stm32f429.ld` 链接脚本（flash 2MB @0x08000000，SRAM 192KB @0x20000000）
- `main.c` 寄存器级全部逻辑：tree_probe / uart_init / 解码打印

## 构建（本机已验证）

```bash
. ~/esp/esp-idf/export.sh 2>/dev/null; # 无需，直接用 arm-none-eabi-gcc 15.x
cd practice/f429-lab/rcc-uart-read && make
```

## 真机（挑战者 F429-V2，DAP + openocd）

```bash
make flash   # cmsis-dap + stm32f4x.cfg
make term    # /dev/ttyUSB0 @115200（USART1 PA9/PA10 -> CH340）
```

## 预期输出（clock_init 后的典型态；上电默认 HSI 态则为 16MHz 系列数字）

```text
=== RCC 三连 @ 0x40023800 ===
RCC_CR     = 0x03035883  HSI:RDY  HSE:RDY  PLL:LOCKED
RCC_PLLCFGR= 0x07405a19  M=25 N=360 P=/2 Q=/7 SRC=HSE
RCC_CFGR   = 0x0000940a  SWS=PLL HPRE=/1 PPRE1=/4 PPRE2=/2
=> SYSCLK=180MHz HCLK=180MHz PCLK1=45MHz PCLK2=90MHz
SysTick: CTRL=0x00000?05 LOAD=0x0002bf1f => tick=1000Hz
```

> [!WARNING]
> 输出块为按 RM0090 位段推演的预期形态，**真机数值待上板核对**（对照章内实测
> `03035883/07405a19/0000940a`、tick 1000.5Hz）。QEMU 无 F429 机型（netduinoplus2
> 的 RCC/USART1 模型残缺），本工程以编译验证为准。
