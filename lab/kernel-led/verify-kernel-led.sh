#!/bin/bash
# verify-kernel-led.sh — 验证 Linux 内核模块版 LED 驱动
#
# 编译模块 → 放进 initramfs → 启动 qemu → insmod 加载 → 检查日志
# 用法：./verify-kernel-led.sh

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$DIR/.." && pwd)"
KERNEL_DIR="$LAB_DIR/linux-6.19"
KVER=6.19

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok(){ echo -e "${GREEN}[✓]${NC} $1"; }
die(){ echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ---------- 1. 编译模块 ----------
echo "=== [1/4] 编译 LED 内核模块 ==="
cd "$DIR"
make clean 2>/dev/null || true
make ARCH=arm CROSS_COMPILE=arm-linux-gnu- -C "$KERNEL_DIR" M="$DIR" modules 2>&1 | tail -3
[ -f led_module.ko ] || die "模块编译失败"
ok "led_module.ko 编译完成"

# ---------- 2. 放进 initramfs ----------
echo
echo "=== [2/4] 重新组装 initramfs（含 led_module.ko） ==="
cd "$LAB_DIR"
cp kernel-led/led_module.ko initramfs/
# init 脚本：启动网络+dropbear，然后 insmod LED 模块
cat > initramfs/init <<'EOF'
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mkdir -p /dev/pts /var/run /var/log /tmp
mount -t devpts devpts /dev/pts
ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up
telnetd -l /bin/sh
/usr/sbin/dropbear -E -B -p 22
echo "=== READY ==="
# 加载 LED 模块并捕获 dmesg
echo "Loading LED module..."
insmod /led_module.ko
sleep 3
echo "=== DMESG LED OUTPUT ==="
dmesg | grep -i 'led\|LED\|gpio\|probe' | tail -20
echo "=== DMESG END ==="
echo "=== DONE ==="
exec /bin/busybox sh
EOF
chmod +x initramfs/init

cd initramfs && find . | cpio -o -H newc 2>/dev/null | gzip > ../initramfs_led.cpio.gz && cd ..
ok "initramfs_led.cpio.gz 就绪"

# ---------- 3. 启动 qemu ----------
echo
echo "=== [3/4] 启动 qemu ==="
QEMU_LOG="/tmp/verify-kernel-led.log"
QEMU_PID_FILE=$(mktemp -u /tmp/vkled.XXXX.pid)
rm -f "$QEMU_LOG"
cleanup(){ QPID=$(cat "$QEMU_PID_FILE" 2>/dev/null || true); [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; rm -f "$QEMU_PID_FILE"; }
trap cleanup EXIT

qemu-system-arm -M vexpress-a9 -smp 4 -m 512M \
    -kernel "$KERNEL_DIR/arch/arm/boot/zImage" \
    -dtb "$KERNEL_DIR/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb" \
    -initrd initramfs_led.cpio.gz \
    -append "console=ttyAMA0" \
    -net nic,model=lan9118 -net user,hostfwd=tcp:127.0.0.1:5555-:22,hostfwd=tcp:127.0.0.1:5556-:23 \
    -device virtio-rng-device \
    -nographic -serial "file:$QEMU_LOG" -monitor none -display none \
    -pidfile "$QEMU_PID_FILE" &
disown

# 等 DONE 出现
READY=0
for i in $(seq 1 30); do
    grep -q 'DONE' "$QEMU_LOG" 2>/dev/null && { READY=1; break; }
    sleep 1
done
[ "$READY" -eq 1 ] || { tail -20 "$QEMU_LOG"; die "qemu 未完成"; }
ok "qemu 运行完成"

# ---------- 4. 验证 dmesg 输出 ----------
echo
echo "=== [4/4] 验证 LED 模块日志 ==="

# 提取 dmesg LED 输出段
DMESG=$(sed -n '/DMESG LED OUTPUT/,/DMESG END/p' "$QEMU_LOG" 2>/dev/null)
echo "$DMESG" | head -25

echo "$DMESG" | grep -q 'Kernel LED Driver (module)' || { echo "$DMESG"; die "未见本模块启动标志"; }
ok "LED 模块启动"

ON_COUNT=$(echo "$DMESG" | grep -c 'LED ON  (iteration')
OFF_COUNT=$(echo "$DMESG" | grep -c 'LED OFF (iteration')
[ "$ON_COUNT" -ge 5 ] && [ "$OFF_COUNT" -ge 5 ] || { echo "$DMESG"; die "闪烁次数不足 ON=$ON_COUNT OFF=$OFF_COUNT"; }
ok "闪烁序列完整（ON×$ON_COUNT / OFF×$OFF_COUNT）"

echo "$DMESG" | grep -q 'Kernel LED Driver done' || { echo "$DMESG"; die "模块未正常完成"; }
ok "模块正常完成"

# 检查 insmod 是否成功
grep -qi 'insmod.*fail\|Unable to\|conflict\|not.*load' "$QEMU_LOG" 2>/dev/null && die "insmod 失败" || true
ok "模块加载成功"

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} [✓] 内核模块加载+执行链路验证通过 ${NC}"
echo -e "${GREEN}     （LED 寄存器控制受内置驱动并发影响，未验证 LED 状态正确性） ${NC}"
exit 0
