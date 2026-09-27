#!/usr/bin/env python3
"""树莓派 GPIO 频率计——pigpio 回调计边沿数 + 闸门时间测频。

依赖安装（树莓派上执行一次）：
    sudo apt install pigpio python3-pigpio    # 守护进程 + Python 绑定
    sudo systemctl enable --now pigpiod        # 启动守护进程
    # 测 kHz 级信号请用 1µs 采样档（默认 5µs 会漏边沿）：
    sudo killall pigpiod 2>/dev/null; sudo pigpiod -s 1

用法示例（在本工程 tools/ 目录下）：
    python3 tools/measure_freq.py                          # GPIO17，2s 闸门，每轮间隔 1s
    python3 tools/measure_freq.py --gpio 27 --gate 10      # 10s 闸门（ppm 级精度）
    python3 tools/measure_freq.py --gpio 17 --interval 0   # 轮与轮之间不歇，连续测

读数口径：
    频率 = 闸门内上升沿计数 / 闸门时长；每轮打印本次值与累计均值，Ctrl-C 退出时给汇总。
    ±1 边沿量化误差 = 1/边沿总数：32768Hz 用 2s 闸门约 ±15ppm/轮，ppm 级判读请 --gate 10 以上。
    pigpio 1µs 采样档可靠检测的边沿事件上限约 500kHz——更高的频率请在 4040 分频输出上测，
    读数 ×2^n 还原（详见 docs/instruments.md §3）。
"""

import argparse
import sys
import time

import pigpio


def main():
    p = argparse.ArgumentParser(description="pigpio 回调式 GPIO 频率计（边沿计数 + 闸门时间）")
    p.add_argument("--gpio", type=int, default=17, help="采样 GPIO 编号（BCM 命名，默认 17=物理脚11）")
    p.add_argument("--gate", type=float, default=2.0, help="闸门秒数（默认 2；ppm 级精度建议 10+）")
    p.add_argument("--interval", type=float, default=1.0, help="两轮测量之间的间隔秒数（默认 1，0=连测）")
    args = p.parse_args()
    if args.gate <= 0:
        sys.exit("--gate 必须为正数")
    if args.interval < 0:
        sys.exit("--interval 不能为负")

    pi = pigpio.pi()  # 连接本机 pigpiod（默认 localhost:8888）
    if not pi.connected:
        sys.exit("连不上 pigpiod：先 sudo systemctl start pigpiod（kHz 级请用 1µs 档：sudo pigpiod -s 1）")

    # 只数上升沿。用 tally/reset 计数而不是边沿时间戳：绕开 pigpio tick 的 32 位微秒回绕，
    # 也让长闸门（10s+）不必自己处理溢出。
    cb = pi.callback(args.gpio, pigpio.RISING_EDGE)

    freqs = []
    print(f"# GPIO{args.gpio}  gate={args.gate}s  interval={args.interval}s  （Ctrl-C 结束）")
    try:
        while True:
            time.sleep(args.gate)  # 闸门：期间 daemon 在后台累加该脚的上升沿计数
            edges = cb.tally()     # 读走闸门内的上升沿总数
            cb.reset()             # 清零，下一轮从 0 起算
            f = edges / args.gate
            freqs.append(f)
            avg = sum(freqs) / len(freqs)
            print(f"#{len(freqs):<4d} {f:>12.1f} Hz   累计均值 {avg:>12.1f} Hz")
            if args.interval > 0:
                time.sleep(args.interval)
    except KeyboardInterrupt:
        pass  # Ctrl-C 是正常退出路径，汇总在 finally 之后打印
    finally:
        cb.cancel()  # 注销回调
        pi.stop()    # 断开与 pigpiod 的连接

    if freqs:
        avg = sum(freqs) / len(freqs)
        print(f"\n共 {len(freqs)} 轮：均值 {avg:.1f} Hz，最小 {min(freqs):.1f} Hz，最大 {max(freqs):.1f} Hz")
        print(f"±1 边沿量化误差量级：{1.0 / (freqs[-1] * args.gate) * 1e6:.1f} ppm/轮（最后一轮口径）")


if __name__ == "__main__":
    main()
