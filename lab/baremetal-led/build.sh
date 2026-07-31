#!/bin/bash
# build.sh — 编译裸机 LED 驱动
# 用法：./build.sh
set -euo pipefail

CC=arm-linux-gnu-gcc
LD=arm-linux-gnu-ld
OC=arm-linux-gnu-objcopy

echo "=== 编译裸机 LED 驱动 ==="

# 汇编启动代码
$CC -c -march=armv7-a -ffreestanding start.S -o start.o
echo "  [✓] start.S -> start.o"

# C 代码（裸机，无标准库，无 PIC）
$CC -c -march=armv7-a -ffreestanding -fno-pic -O2 led.c -o led.o
echo "  [✓] led.c -> led.o"

# 链接（用自定义链接脚本，入口 0x60000000）
$LD -T linker.ld start.o led.o -o led_blink.elf
# 转 raw binary（备用，某些场景需要）
$OC -O binary led_blink.elf led_blink.bin
echo "  [✓] led_blink.bin ($(stat -c%s led_blink.bin) bytes) + led_blink.elf"

# 验证架构
file led_blink.elf
echo "=== 编译完成 ==="
echo "运行: qemu-system-arm -M vexpress-a9 -m 512M -kernel led_blink.elf -nographic -serial stdio -monitor none -display none"

