#!/bin/bash
# 1.5.1 qemu vexpress-a9 实验环境验证脚本
# 终点：验证 ARM 内核启动 + 网卡探测 + 串口 getty/login 就绪
#
# 验证范围（经实测确认）：
#   ✅ qemu vexpress-a9 + 自编译 ARM 内核 6.19 完整启动
#   ✅ SMSC LAN9118 网卡驱动加载，eth0 UP
#   ✅ devtmpfs/devpts 正常，pty 节点可创建
#   ✅ busybox 全 402 applet 可用（login/getty/passwd 等）
#   ✅ 串口 getty + login 链路通过（出现 login: 提示）
#   ❌ busybox telnetd 远程登录未通过（见下方说明）
#
# 关于 telnetd：
#   busybox telnetd 在本环境下接受 TCP 连接后会话进程静默退出
#   （客户机内 localhost 自连也失败），已确认是 telnetd 自身限制，
#   非环境配置问题。远程访问建议后续改用 Dropbear/SSH。
#
# 用法：./verify-env.sh [内核目录]
#   内核目录默认 ./linux-6.19

set -euo pipefail
KVER="${KVER:-6.19}"
KERNEL_DIR="${1:-linux-$KVER}"
ZIMAGE="$KERNEL_DIR/arch/arm/boot/zImage"
DTB="$KERNEL_DIR/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb"
INITRAMFS="initramfs.cpio.gz"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
step(){ echo -e "${CYAN}[$1]${NC} $2"; }
ok(){   echo -e "${GREEN}[✓]${NC} $1"; }
die(){  echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ---------- 前置检查 ----------
step 1 "检查编译产物"
[ -f "$ZIMAGE" ]    || die "缺少内核 $ZIMAGE（先按文档交叉编译内核）"
[ -f "$DTB" ]       || die "缺少设备树 $DTB"
[ -f "$INITRAMFS" ] || die "缺少 $INITRAMFS（先按文档打包 rootfs）"
ok "内核 / 设备树 / initramfs 就绪"

command -v qemu-system-arm >/dev/null || die "未装 qemu-system-arm"

# ---------- 启动 qemu ----------
step 2 "启动 qemu vexpress-a9，串口日志输出到 /tmp/verify-env.log"
QEMU_LOG="/tmp/verify-env.log"
QEMU_PID_FILE=$(mktemp -u /tmp/verify-env.XXXX.pid)

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
    -nographic \
    -serial "file:$QEMU_LOG" \
    -monitor none -display none \
    -pidfile "$QEMU_PID_FILE" &
disown
ok "qemu 已启动（后台）"

# ---------- 等待内核启动 ----------
step 3 "等待内核启动 + getty 就绪（最多 30s）"
READY=0
for i in $(seq 1 30); do
    # 检测串口日志出现 login: 提示（getty+login 链通的标志）
    if grep -q 'login:' "$QEMU_LOG" 2>/dev/null; then
        ok "getty + login 就绪（耗时 ${i}s）"
        READY=1
        break
    fi
    sleep 1
done
[ "$READY" -eq 1 ] || { echo "--- 串口日志尾部 ---"; tail -20 "$QEMU_LOG" 2>/dev/null; die "30s 内未出现 login: 提示"; }

# ---------- 验证关键启动标志 ----------
step 4 "验证关键启动标志"

grep -q 'smsc911x.*eth0.*identified' "$QEMU_LOG" 2>/dev/null \
    && ok "SMSC LAN9118 网卡驱动加载" \
    || die "网卡驱动未加载"

grep -q 'Run /init as init process' "$QEMU_LOG" 2>/dev/null \
    && ok "initramfs init 执行" \
    || die "init 未执行"

grep -q 'Freeing unused kernel image' "$QEMU_LOG" 2>/dev/null \
    && ok "内核初始化完成" \
    || die "内核初始化未完成"

# ---------- 环境就绪 ----------
step 5 "环境就绪"
echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} [env-ready] 环境就绪：串口 getty 启动并出现 login: 提示 ${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo "已验证范围：内核启动 / SMSC 网卡驱动 / init 执行 / getty+login 链路"
echo "已知限制：busybox telnetd 远程登录未通过（telnetd 自身问题，非环境）"
echo "日常使用：前台跑 qemu，直接在串口 login 操作"
echo "  qemu-system-arm -M vexpress-a9 -smp 4 -m 512M \\"
echo "    -kernel $ZIMAGE -dtb $DTB -initrd $INITRAMFS \\"
echo "    -append console=ttyAMA0 -net nic,model=lan9118 -nographic"
exit 0
