#!/bin/bash
# verify-led.sh — 验证裸机 LED 驱动
#
# 编译 → 运行 → 检查串口输出有 LED ON/OFF 闪烁
# 用法：./verify-led.sh [项目目录]
#   默认项目目录 = 脚本所在目录

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ELF="$DIR/led_blink.elf"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok(){ echo -e "${GREEN}[✓]${NC} $1"; }
die(){ echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ---------- 1. 编译 ----------
echo "=== [1/3] 编译 ==="
cd "$DIR"
bash build.sh || die "编译失败"
[ -f "$ELF" ] || die "缺少 $ELF"
ok "编译完成"

# ---------- 2. 运行 ----------
echo
echo "=== [2/3] 运行 qemu ==="
OUTPUT=$(timeout 15 qemu-system-arm -M vexpress-a9 -m 512M \
    -kernel "$ELF" \
    -nographic -serial stdio -monitor none -display none 2>&1 || true)

# ---------- 3. 验证输出 ----------
echo
echo "=== [3/3] 验证输出 ==="
echo "$OUTPUT" | grep -q "Bare-metal LED Driver" || { echo "$OUTPUT"; die "未见 LED 驱动启动标志"; }
ok "LED 驱动启动"

ON_COUNT=$(echo "$OUTPUT" | grep -c "LED ON")
OFF_COUNT=$(echo "$OUTPUT" | grep -c "LED OFF")
echo "  LED ON 次数: $ON_COUNT"
echo "  LED OFF 次数: $OFF_COUNT"
[ "$ON_COUNT" -ge 3 ] && [ "$OFF_COUNT" -ge 3 ] || { echo "$OUTPUT"; die "LED 闪烁次数不足"; }
ok "LED 闪烁序列完整（ON×$ON_COUNT / OFF×$OFF_COUNT）"

echo "$OUTPUT" | grep -q "readback" || { echo "$OUTPUT"; die "未见寄存器读回"; }
ok "寄存器读回验证"

echo "$OUTPUT" | grep -q "DONE" || { echo "$OUTPUT"; die "程序未正常完成"; }
ok "程序正常完成"

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} [✓] 裸机 LED 驱动验证通过 ${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo "宿主机感知方式：串口打印（LED ON/OFF）+ 寄存器读回（写入真实生效）"
exit 0
