#!/bin/bash
# verify-telnet.sh — telnetd expect 交互式验证（端口 5556→23）
# telnetd -l /bin/sh 绕过登录，无 login: 提示、无口令，直接进 ~ # shell。
# 必须用 expect 保持连接，不能用管道（管道 EOF 会触发 SIGHUP）。
set -euo pipefail
KVER="${KVER:-6.19}"
KERNEL_DIR="${1:-linux-$KVER}"
ZIMAGE="$KERNEL_DIR/arch/arm/boot/zImage"
DTB="$KERNEL_DIR/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb"
INITRAMFS="initramfs.cpio.gz"
HOST_PORT=5556

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok(){ echo -e "${GREEN}[✓]${NC} $1"; }
die(){ echo -e "${RED}[✗]${NC} $1"; exit 1; }

[ -f "$ZIMAGE" ]    || die "缺少内核 $ZIMAGE"
[ -f "$DTB" ]       || die "缺少设备树 $DTB"
[ -f "$INITRAMFS" ] || die "缺少 $INITRAMFS"
command -v expect >/dev/null || die "未装 expect"

QEMU_LOG="/tmp/verify-telnet.log"
QEMU_PID_FILE=$(mktemp -u /tmp/vt.XXXX.pid)
rm -f "$QEMU_LOG"
cleanup(){ QPID=$(cat "$QEMU_PID_FILE" 2>/dev/null || true); [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; rm -f "$QEMU_PID_FILE"; }
trap cleanup EXIT

qemu-system-arm -M vexpress-a9 -smp 4 -m 512M \
    -kernel "$ZIMAGE" -dtb "$DTB" -initrd "$INITRAMFS" \
    -append "console=ttyAMA0" \
    -net nic,model=lan9118 -net user,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:23 \
    -device virtio-rng-device \
    -nographic -serial "file:$QEMU_LOG" -monitor none -display none \
    -pidfile "$QEMU_PID_FILE" &
disown

for i in $(seq 1 20); do grep -q 'READY' "$QEMU_LOG" 2>/dev/null && break; sleep 1; done
grep -q 'READY' "$QEMU_LOG" 2>/dev/null || { tail -15 "$QEMU_LOG"; die "客户机未就绪"; }

export HOST_PORT
RESULT=$(expect <<'EXPECT' 2>&1 || true
set timeout 15
spawn telnet 127.0.0.1 $env(HOST_PORT)
expect -re "# *$"
send "id\r"
expect -re "uid=0"
send "exit\r"
expect eof
EXPECT
)

if echo "$RESULT" | grep -q 'uid=0'; then
    ok "telnet 登录成功，root shell"
    echo "$RESULT" | grep 'uid=' | head -1
else
    echo "$RESULT" | tail -10
    die "telnet 登录失败"
fi
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} [✓] telnet 远程登录验证通过 ${NC}"
echo -e "${GREEN}========================================${NC}"
exit 0
