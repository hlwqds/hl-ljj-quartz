#!/bin/bash
# 1.5.1 qemu vexpress-a9 实验环境验证脚本
# 终点：从宿主机 SSH 登录客户机并执行命令，验证 uid=0(root)
#
# 验证范围（经实测确认）：
#   ✅ qemu vexpress-a9 + 自编译 ARM 内核 6.19 完整启动
#   ✅ SMSC LAN9118 网卡驱动加载，eth0 UP (10.0.2.15)
#   ✅ qemu hostfwd 端口转发 (宿主 5555 → 客户机 22)
#   ✅ virtio-rng 提供硬件熵源，CRNG 秒级就绪
#   ✅ dropbear SSH 服务端启动，空口令 root 登录
#   ✅ 从宿主机 SSH 登录拿到 root shell，执行 id/uname
#
# 关于 busybox telnetd：
#   busybox telnetd fork 出的子进程被内核 SIGHUP 杀死（strace 确认），
#   是 telnetd 在 vfork+setsid+pty 路径上的已知限制，非配置问题。
#   本系列使用 SSH（dropbear）作为远程访问方式。
#
# 用法：./verify-ssh.sh [内核目录]
#   内核目录默认 ./linux-6.19

set -euo pipefail
KVER="${KVER:-6.19}"
KERNEL_DIR="${1:-linux-$KVER}"
ZIMAGE="$KERNEL_DIR/arch/arm/boot/zImage"
DTB="$KERNEL_DIR/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb"
INITRAMFS="initramfs.cpio.gz"

HOST_PORT=5555

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
step(){ echo -e "${CYAN}[$1]${NC} $2"; }
ok(){   echo -e "${GREEN}[✓]${NC} $1"; }
die(){  echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ---------- 前置检查 ----------
step 1 "检查编译产物"
[ -f "$ZIMAGE" ]    || die "缺少内核 $ZIMAGE"
[ -f "$DTB" ]       || die "缺少设备树 $DTB"
[ -f "$INITRAMFS" ] || die "缺少 $INITRAMFS"
ok "内核 / 设备树 / initramfs 就绪"

command -v qemu-system-arm >/dev/null || die "未装 qemu-system-arm"
command -v ssh >/dev/null || die "未装 ssh 客户端"

# ---------- 启动 qemu ----------
step 2 "启动 qemu vexpress-a9（virtio-rng + dropbear SSH）"
QEMU_LOG="/tmp/verify-ssh.log"
QEMU_PID_FILE=$(mktemp -u /tmp/verify-ssh.XXXX.pid)

cleanup(){
    QPID=$(cat "$QEMU_PID_FILE" 2>/dev/null || true)
    [ -n "$QPID" ] && kill "$QPID" 2>/dev/null && echo "  清理 qemu (pid $QPID)"
    rm -f "$QEMU_PID_FILE"
}
trap cleanup EXIT

rm -f "$QEMU_LOG"
qemu-system-arm \
    -M vexpress-a9 \
    -smp 4 \
    -m 512M \
    -kernel "$ZIMAGE" \
    -dtb "$DTB" \
    -initrd "$INITRAMFS" \
    -append "console=ttyAMA0" \
    -net nic,model=lan9118 \
    -net user,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:22 \
    -device virtio-rng-device \
    -nographic \
    -serial "file:$QEMU_LOG" \
    -monitor none -display none \
    -pidfile "$QEMU_PID_FILE" &
disown
ok "qemu 已启动（后台）"

# ---------- 等待 dropbear 就绪 ----------
step 3 "等待 CRNG + dropbear 就绪（最多 20s）"
READY=0
for i in $(seq 1 20); do
    if grep -q 'READY' "$QEMU_LOG" 2>/dev/null && \
       grep -q 'crng init done' "$QEMU_LOG" 2>/dev/null; then
        ok "CRNG + dropbear 就绪（耗时 ${i}s）"
        READY=1
        break
    fi
    sleep 1
done
[ "$READY" -eq 1 ] || { echo "--- 串口日志尾部 ---"; tail -20 "$QEMU_LOG" 2>/dev/null; die "dropbear 未就绪"; }

# ---------- SSH 验证 ----------
step 4 "SSH 登录客户机并执行命令"
RESULT=$(sshpass -p '' ssh -p "$HOST_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    root@127.0.0.1 'id; uname -a' 2>&1 || true)

echo "$RESULT" | grep -q 'uid=0(root)' \
    && ok "SSH 登录成功，root shell" \
    || { echo "--- SSH 输出 ---"; echo "$RESULT" | tail -10; die "SSH 登录失败"; }

echo "$RESULT" | grep -qi 'Linux' \
    && ok "客户机内核响应 uname" \
    || die "未看到内核信息"

# ---------- 验证通过 ----------
step 5 "验证完成"
echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} [✓] SSH 远程登录验证通过 ${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo "已验证：内核启动 / 网卡 / CRNG(virtio-rng) / dropbear SSH / root 登录"
echo "日常使用：另开终端 ssh -p 5555 root@127.0.0.1（空口令）"
exit 0
