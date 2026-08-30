# ch06-uart-framing — UART 成帧协议状态机（QEMU 实证）

《嵌入式硬件基础》系列（ch06）配套工程：在
[[ch04-baremetal-template]] 的裸机模板上加 UART **接收**侧与一个
逐字节成帧状态机，用 QEMU 注入好帧/坏帧序列验证六类事件。

对应文章：`content/2026-08-30-embedded-basics-ch06-uart-protocol.md`

## 帧格式

```text
'$' seq(2 hex) ',' payload(1..64B) '*' xor(2 hex) '\n'
```

- `seq`：0~255 循环递增，接收方据此推断丢帧（GAP）
- `xor`：`'$'` 与 `'*'` 之间（含 seq、逗号、payload）全部字节的异或，
  2 位十六进制（NMEA 0183 风格）
- payload 为 `STATS` 的帧是命令帧：接收方回打印统计块

六类事件：`OK`（好帧）/ `BADCS`（校验错）/ `GAP`（序号跳变=丢帧推断）/
`OLONG`（payload 超过 64B，保护性弃帧）/ `UNTERM`（`\n` 早到，帧被截断）/
`STRAY`（帧间垃圾或帧内非法字符，丢帧后于下一个 `$` 再同步）。

## 文件清单

| 文件            | 职责                                                     |
| --------------- | -------------------------------------------------------- |
| `startup.S`     | ch04 模板原样复用（向量表 + Reset_Handler + 弱符号兜底） |
| `mps2_an385.ld` | ch04 模板原样复用（FLASH 512K / RAM 128K）               |
| `main.c`        | UART 收/发 + 帧状态机 + 事件打印 + 统计                  |
| `gen_input.py`  | 注入流生成器（好帧 + 五类坏帧/噪声，校验自动计算）       |
| `Makefile`      | 构建 + `make run`（交互）/ `make test`（自动化实证）     |

## 环境

- `arm-none-eabi-gcc`（测试版本 15.2.0）
- `qemu-system-arm`（测试版本 10.1.5）
- 机型 `-M mps2-an385`（Cortex-M3，CMSDK APB UART0 @ 0x40004000）

## 用法

```bash
make            # 编译 + 链接（text 2460 / bss 120 字节）
make run        # 交互：键盘输入直接进 UART0 RX（Ctrl-A X 退出）
make test       # 自动化：生成注入流 -> QEMU 回环 -> 打印 run.log
make disasm     # 反汇编摘录
```

手动注入任意序列：

```bash
python3 gen_input.py > build/in.bin
timeout 5 qemu-system-arm -M mps2-an385 -kernel build/ch06-uart-framing.elf \
  -display none -serial stdio < build/in.bin
```

`-serial stdio` 把 UART0 接到 stdio：程序打印走 TX，stdin 字节进 RX。
`timeout` 到期杀掉 QEMU（程序收完字节后自旋等待下一字节）属预期。

## 预期输出（真实运行，`make test`）

```text
ch06 uart framing receiver on mps2-an385
frame := '$' seq(2hex) ',' payload '*' xor(2hex) '\n'
feed stdin -> uart0 rx; send a STATS frame for counters
[OK    ] seq 00 4B 'PING'
[OK    ] seq 01 5B 'LED=1'
[OK    ] seq 02 9B 'TEMP=22.5'
[BADCS ] frame seq 03 csum got 0x22 want 0x78: dropped
[GAP   ] seq 04 -> 06:2 frame(s) missing (inferred)
[OK    ] seq 06 4B 'GAP2'
[OLONG ] payload > 64 bytes: frame dropped
[STRAY ] 8 junk bytes (last 0x42) skipped, locked at '$'
[UNTERM] \n at state PAYLOAD: frame cut short, dropped
[STRAY ] 5 junk bytes (last 0x21) skipped, locked at '$'
[GAP   ] seq 07 -> 09:2 frame(s) missing (inferred)
[OK    ] seq 09 6B 'RESYNC'
[OK    ] seq 0a 5B 'STATS'
---- rx stats ----
bytes rx     : 185
OK     events: 6
BADCS  events: 1
GAP    events: 2
OLONG  events: 1
UNTERM events: 1
STRAY  events: 2
frames lost  : 4 (inferred from gaps)
junk bytes   : 13
resyncs      : 4
-----------------
qemu-system-arm: terminating on signal 15 from pid 88815 (timeout)
```

交叉验证：`wc -c build/in.bin` = 185 = `bytes rx`——注入流每个字节都被
状态机消费，无一丢失（QEMU chardev 在 RX_EN 置位前于后端排队，见下）。

注意第二次 GAP：seq 07/08 其实是"收到了但坏了"（OLONG/UNTERM 弃帧），
而 GAP 把它们记成 missing——**GAP 只能证明序号没连上，不能区分"没发"和
"坏了"**，这是板间协议统计口径必须写清的取舍（文章 6.6 节展开）。

## QEMU 模型边界（hw/char/cmsdk-apb-uart.c v10.1 源码考证）

| 行为                    | 模型语义                                                              |
| ----------------------- | --------------------------------------------------------------------- |
| `CTRL.RX_EN=0` 时来字节 | chardev 层不投递（`uart_can_receive` 返回 0），字节在宿主侧排队不丢   |
| `STATE.RXFULL`（bit1）  | RX 缓冲**非空**即置位；模型缓冲深度 = 1 字节（非 FIFO）               |
| 读 `DATA`               | 返回该字节并清 RXFULL；随后 `accept_input` 放行下一个字节             |
| 波特率/起始位/过采样    | **不仿真**：字节直通，位级时序（容差、过采样、毛刺）需真机/逻辑分析仪 |

因此本工程验证的是**成帧状态机与字节流鲁棒性**；位级协议行为（波特率
容差、16 倍过采样）见文章 6.2 节的理论推导，真机实证在破坏性实验表占位。

## 换到真机（板到后）

- STM32F407：USART1（PA9/PA10，AF7），RM0090 §19 寄存器布局与 CMSDK 不同，
  `uart_getc/uart_putc` 换成读 `USART_SR.RXNE`/写 `USART_DR` 即可，
  状态机代码零改动；
- GD32VF103：USART0（PA9/PA10），GD32VF103 用户手册 §16，同为 3.3V，
  与 F407 直连（TX/RX 交叉 + 共地）；
- 建议补帧间超时（本章纯字节驱动，需 ch08 的定时基准）。

构建产物 `build/` 已被 `.gitignore`（`practice/*/build*/`）排除。
