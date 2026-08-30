#!/usr/bin/env python3
"""生成 UART TX 数字波形样本，喂给 sigrok-cli 做零硬件解码自检。

模拟场景：逻辑分析仪 1 通道夹在 UART TX 线上，抓到若干字节（默认 0x55 0xAA）。

信号模型分两层，和真实世界对齐：
1. 理想信号是一条连续时间线（一组 (时刻, 电平) 边沿）；
2. 采样器以 --rate 的节拍对它取样，每个采样点落进哪个电平区间就记哪个电平。

因此同一条理想信号可以用不同采样率重采：24 MHz 能看到的 100 ns 毛刺，
1 MHz 重采后会自然消失（采样时刻没落在毛刺窗口内），不需要人为造假。

输出 raw binary（每字节 1 个采样，bit0 = D0），解码命令：

    sigrok-cli -i uart_55aa.sr.bin -I binary:numchannels=1:samplerate=24000000 \
        -P uart:baudrate=115200:tx=0 \
        -A uart=tx-start:tx-data:tx-stop:tx-warnings --protocol-decoder-samplenum
"""

import argparse
import bisect


def build_uart_edges(data: bytes, baud: int, idle_bits_before: float = 2.0,
                     idle_bits_after: float = 2.0) -> list[tuple[float, int]]:
    """构造 8N1 UART TX 的连续时间边沿表，单位纳秒。

    返回按时间排序的 [(t_ns, level), ...]，t_ns 之前保持上一电平，初始 idle 高。
    每帧：起始位 0 + 8 数据位（LSB first）+ 停止位 1。
    """
    bit_ns = 1e9 / baud
    t = idle_bits_before * bit_ns
    edges: list[tuple[float, int]] = []

    def to(level: float) -> None:
        nonlocal t
        edges.append((t, int(level)))
        t += bit_ns

    for byte in data:
        frame = [0] + [(byte >> i) & 1 for i in range(8)] + [1]
        for b in frame:
            to(b)
    t += idle_bits_after * bit_ns
    return edges


def inject_glitch(edges: list[tuple[float, int]], baud: int, frame: int, bit: int,
                  glitch_ns: int, frac: float = 0.25, idle_bits_before: float = 2.0) -> None:
    """在 frame 帧（0 起）第 bit 比特（0=起始位）的 frac 处注入反相毛刺。

    模拟真实信号里的振铃/串扰尖峰：宽度远小于一个比特时间。
    """
    bit_ns = 1e9 / baud
    t0 = (idle_bits_before + frame * 10 + bit) * bit_ns + frac * bit_ns
    bisect.insort(edges, (t0, 0))
    bisect.insort(edges, (t0 + glitch_ns, 1))


def level_at(edges: list[tuple[float, int]], t_ns: float) -> int:
    """二分查找 t_ns 时刻的电平（边沿表初始为 idle 高）。"""
    i = bisect.bisect_right(edges, (t_ns, 2)) - 1
    return 1 if i < 0 else edges[i][1]


def sample(edges: list[tuple[float, int]], rate: int) -> bytes:
    """以 rate Hz 对连续信号采样：每字节 1 个采样，bit0 = D0。"""
    step_ns = 1e9 / rate
    total_ns = edges[-1][0] if edges else 0
    n = int(total_ns / step_ns) + 1
    return bytes(level_at(edges, i * step_ns) & 1 for i in range(n))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--rate", type=int, default=24_000_000)
    ap.add_argument("--data", default="55aa", help="hex 字符串，如 55aa")
    ap.add_argument("--glitch-ns", type=int, default=0,
                    help="在第 2 帧第 3 比特注入 100ns 级反相毛刺（0=不加）")
    ap.add_argument("-o", "--output", default="uart_55aa.sr.bin")
    args = ap.parse_args()

    data = bytes.fromhex(args.data)
    edges = build_uart_edges(data, args.baud)
    if args.glitch_ns:
        inject_glitch(edges, args.baud, frame=1, bit=2, glitch_ns=args.glitch_ns)
    wav = sample(edges, args.rate)

    with open(args.output, "wb") as f:
        f.write(wav)
    print(f"wrote {args.output}: {len(wav)} samples @ {args.rate} Hz "
          f"({len(wav) / args.rate * 1000:.3f} ms)")
    print(f"samples/bit = {args.rate / args.baud:.2f}  ({args.rate}/{args.baud})")


if __name__ == "__main__":
    main()
