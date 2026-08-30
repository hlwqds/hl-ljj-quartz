# ch02-la-uart：零硬件 UART 波形生成 + sigrok 解码实验

配套文章：《嵌入式硬件基础（二）：工具驯化——万用表与逻辑分析仪》
（`content/2026-08-30-embedded-basics-ch02-tools-multimeter-la.md`）。

## 原理

`gen_uart_sr.py` 分两层建模：

1. 连续时间信号：一组 `(时刻 ns, 电平)` 边沿，构造 8N1 UART TX
   （idle 高 + 起始位 0 + 8 数据位 LSB first + 停止位 1）；
2. 采样器：以 `--rate` 节拍取样，每字节 1 个采样（bit0 = D0），输出 raw binary。

同一理想信号可用不同采样率重采，用于验证"采样率 ≥10×"规则
（理想波形低倍率也能解码，但亚比特毛刺会因欠采样而不可见）。

## 复现命令

```bash
# 24 MHz 采样，抓 0x55 0xAA（clone 分析仪最高档对 115200 baud）
python3 gen_uart_sr.py

# 1 MHz 欠采样版本 / 注入 100ns 反相毛刺的版本
python3 gen_uart_sr.py --rate 1000000 -o uart_55aa_1m.sr.bin
python3 gen_uart_sr.py --rate 24000000 --glitch-ns 100 -o uart_55aa_glitch.sr.bin
python3 gen_uart_sr.py --rate 1000000 --glitch-ns 100 -o uart_55aa_glitch_1m.sr.bin

# 解码（注意 samplerate 必须写全数字，Fedora libsigrok 0.5.2 不认 24m 后缀）
sigrok-cli -i uart_55aa.sr.bin -I binary:numchannels=1:samplerate=24000000 \
    -P uart:baudrate=115200:tx=0 \
    -A uart=tx-start:tx-data:tx-stop:tx-warnings --protocol-decoder-samplenum
```

生成的 `.sr.bin` 是可再生产物，不入库。
