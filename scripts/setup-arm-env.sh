#!/bin/bash
# ============================================================
# setup-arm-env.sh — 一键搭建 qemu vexpress-a9 ARM 驱动实验环境
#
# 从零到 SSH 登录验证通过，分 5 阶段：
#   1. 交叉编译内核（zImage + dtb）
#   2. 交叉编译静态 BusyBox
#   3. 交叉编译静态 Dropbear（SSH 服务端）
#   4. 组装 initramfs（busybox + dropbear + host key）
#   5. 启动 qemu + SSH 登录验证
#
# 用法：
#   ./scripts/setup-arm-env.sh              # 全流程
#   ./scripts/setup-arm-env.sh --skip-build # 跳过编译，只组装+验证
#
# 依赖（宿主机）：
#   Fedora: sudo dnf install qemu-system-arm gcc-arm-linux-gnu podman sshpass
#   Debian: sudo apt install qemu-system-arm gcc-arm-linux-gnueabihf podman sshpass
#
# 踩坑记录见 TROUBLESHOOTING.md
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB_DIR="$REPO_DIR/lab"
KVER="${KVER:-6.19}"
KERNEL_DIR="$LAB_DIR/linux-$KVER"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
phase(){ echo -e "\n${CYAN}========== [$1] $2 ==========${NC}"; }
ok(){   echo -e "${GREEN}  [✓]${NC} $1"; }
warn(){ echo -e "${YELLOW}  [!]${NC} $1"; }
die(){  echo -e "${RED}  [✗]${NC} $1"; exit 1; }

SKIP_BUILD=false
[ "${1:-}" = "--skip-build" ] && SKIP_BUILD=true

mkdir -p "$LAB_DIR"
cd "$LAB_DIR"

# ---------- 前置检查 ----------
phase 0 "前置检查"
command -v qemu-system-arm >/dev/null || die "未装 qemu-system-arm"
command -v podman >/dev/null || die "未装 podman（用于 Debian 容器交叉编译）"
command -v sshpass >/dev/null || { warn "未装 sshpass，尝试安装"; sudo dnf install -y sshpass 2>/dev/null || sudo apt install -y sshpass; }
ok "工具链就绪"

# ============================================================
# 阶段 1：交叉编译内核
# ============================================================
phase 1 "交叉编译内核（zImage + dtb）"

if [ -f "$KERNEL_DIR/arch/arm/boot/zImage" ] && \
   [ -f "$KERNEL_DIR/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb" ] && \
   grep -q 'CONFIG_HW_RANDOM_VIRTIO=y' "$KERNEL_DIR/.config" 2>/dev/null; then
    ok "内核已编译且含 HW_RANDOM_VIRTIO，跳过"
else
    warn "需要编译内核（约 2-15 分钟）"

    cd "$LAB_DIR"
    if [ ! -d "linux-$KVER" ]; then
        wget -q "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz"
        tar xf "linux-$KVER.tar.xz"
    fi
    cd "linux-$KVER"

    make ARCH=arm CROSS_COMPILE=arm-linux-gnu- multi_v7_defconfig

    # CONFIG_HW_RANDOM_VIRTIO 默认未开，必须手动开（否则 CRNG 永不就绪）
    sed -i 's/# CONFIG_HW_RANDOM_VIRTIO is not set/CONFIG_HW_RANDOM_VIRTIO=y/' .config || true
    make ARCH=arm CROSS_COMPILE=arm-linux-gnu- olddefconfig

    # 确认关键选项
    for opt in CONFIG_MODULES CONFIG_BLK_DEV_INITRD CONFIG_SMSC911X CONFIG_NET CONFIG_HW_RANDOM_VIRTIO; do
        grep -q "^$opt=y" .config || die "内核配置缺 $opt"
    done
    ok "内核配置确认"

    make ARCH=arm CROSS_COMPILE=arm-linux-gnu- -j"$(nproc)" zImage dtbs
    ok "内核编译完成"
    cd "$LAB_DIR"
fi

ZIMAGE="$KERNEL_DIR/arch/arm/boot/zImage"
DTB="$KERNEL_DIR/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb"
ok "zImage: $ZIMAGE"
ok "dtb: $DTB"

# ============================================================
# 阶段 2：交叉编译静态 BusyBox
# ============================================================
phase 2 "交叉编译静态 BusyBox"

if [ -f "$LAB_DIR/busybox-arm-static" ]; then
    ok "busybox-arm-static 已存在，跳过"
else
    warn "在 Debian 容器里编译（宿主机 Fedora 工具链缺 ARM glibc headers）"
    cd "$LAB_DIR"
    [ -f busybox-1.36.1.tar.bz2 ] || wget -q https://busybox.net/downloads/busybox-1.36.1.tar.bz2

    podman run --rm -v "$LAB_DIR:/work:Z" debian:bookworm bash -c '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq wget build-essential gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf >/dev/null 2>&1
        cd /work
        rm -rf busybox-1.36.1
        tar xf busybox-1.36.1.tar.bz2
        cd busybox-1.36.1
        make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- defconfig
        sed -i "s/# CONFIG_STATIC is not set/CONFIG_STATIC=y/" .config
        yes "" | make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- oldconfig >/dev/null 2>&1
        make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j"$(nproc)"
        cp busybox /work/busybox-arm-static
    '
    ok "BusyBox 编译完成"
    cd "$LAB_DIR"
fi

# ============================================================
# 阶段 3：交叉编译静态 Dropbear
# ============================================================
phase 3 "交叉编译静态 Dropbear（SSH 服务端）"

if [ -f "$LAB_DIR/dropbear-arm-static" ] && [ -f "$LAB_DIR/dropbearkey-arm-static" ]; then
    ok "dropbear 已存在，跳过"
else
    warn "在 Debian 容器里编译"
    cd "$LAB_DIR"

    podman run --rm -v "$LAB_DIR:/work:Z" debian:bookworm bash -c '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq wget bzip2 build-essential gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf >/dev/null 2>&1
        cd /tmp
        wget -q https://matt.ucc.asn.au/dropbear/releases/dropbear-2024.85.tar.bz2
        tar xf dropbear-2024.85.tar.bz2
        cd dropbear-2024.85
        CC=arm-linux-gnueabihf-gcc ./configure --host=arm-linux-gnueabihf --disable-zlib
        make -j"$(nproc)" CC=arm-linux-gnueabihf-gcc LDFLAGS="-static" PROGRAMS="dropbear dropbearkey"
        cp dropbear /work/dropbear-arm-static
        cp dropbearkey /work/dropbearkey-arm-static
    '
    ok "Dropbear 编译完成"
    cd "$LAB_DIR"
fi

# ============================================================
# 阶段 4：组装 initramfs
# ============================================================
phase 4 "组装 initramfs"

cd "$LAB_DIR"
rm -rf initramfs
mkdir -p initramfs/{bin,sbin,etc,etc/dropbear,proc,sys,dev,mnt,usr/sbin,var/run,var/log,tmp,root}

# BusyBox + 全部 applet 链接
cp busybox-arm-static initramfs/bin/busybox
podman run --rm -v "$LAB_DIR:/work:Z" debian:bookworm bash -c '
    apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq qemu-user-static >/dev/null 2>&1
    cd /work/initramfs/bin
    qemu-arm-static ./busybox --list > /tmp/apps.txt 2>/dev/null
    while IFS= read -r a; do ln -sf busybox "$a"; done < /tmp/apps.txt
'
ok "BusyBox + $(find initramfs/bin -type l | wc -l) applet 链接"

# Dropbear + host key
cp dropbear-arm-static initramfs/usr/sbin/dropbear
cp dropbearkey-arm-static initramfs/usr/sbin/dropbearkey
chmod +x initramfs/usr/sbin/dropbear initramfs/usr/sbin/dropbearkey

# 预生成 host key（运行时生成会卡 CRNG 初始化）
if [ ! -f initramfs/etc/dropbear/dropbear_rsa_host_key ]; then
    podman run --rm -v "$LAB_DIR:/work:Z" debian:bookworm bash -c '
        apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq qemu-user-static >/dev/null 2>&1
        qemu-arm-static /work/dropbearkey-arm-static -t rsa -f /work/initramfs/etc/dropbear/dropbear_rsa_host_key -s 2048
    ' >/dev/null 2>&1
fi
ok "Dropbear + RSA host key（预生成，避免运行时 CRNG 阻塞）"

# /etc/passwd, group（root 空口令）
printf 'root::0:0:root:/root:/bin/sh\n' > initramfs/etc/passwd
printf 'root:x:0:\n' > initramfs/etc/group
chmod 700 initramfs/root
ok "/etc/passwd + /root（chmod 700，dropbear 要求）"

# init 脚本
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
echo "=== READY: ssh -p 5555 / telnet -p 5556 root@127.0.0.1 ==="
exec /bin/busybox sh
EOF
chmod +x initramfs/init
ok "init 脚本（telnetd + dropbear -B，IP 10.0.2.15）"

# 打包
cd initramfs
find . | cpio -o -H newc 2>/dev/null | gzip > ../initramfs.cpio.gz
cd ..
ok "initramfs.cpio.gz: $(ls -la initramfs.cpio.gz | awk '{print $5}') bytes"

# ============================================================
# 阶段 5：启动 qemu + SSH 验证
# ============================================================
phase 5 "启动 qemu + SSH 登录验证"

QEMU_LOG="/tmp/setup-arm-qemu.log"
QEMU_PID_FILE=$(mktemp -u /tmp/setup-arm.XXXX.pid)
rm -f "$QEMU_LOG"

cleanup(){
    QPID=$(cat "$QEMU_PID_FILE" 2>/dev/null || true)
    [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
    rm -f "$QEMU_PID_FILE"
}
trap cleanup EXIT

qemu-system-arm \
    -M vexpress-a9 -smp 4 -m 512M \
    -kernel "$ZIMAGE" -dtb "$DTB" \
    -initrd initramfs.cpio.gz \
    -append "console=ttyAMA0" \
    -net nic,model=lan9118 -net user,hostfwd=tcp:127.0.0.1:5555-:22,hostfwd=tcp:127.0.0.1:5556-:23 \
    -device virtio-rng-device \
    -nographic -serial "file:$QEMU_LOG" \
    -monitor none -display none \
    -pidfile "$QEMU_PID_FILE" &
disown
ok "qemu 启动（后台）"

# 等 CRNG + dropbear 就绪
READY=0
for i in $(seq 1 20); do
    if grep -q 'READY' "$QEMU_LOG" 2>/dev/null && \
       grep -q 'crng init done' "$QEMU_LOG" 2>/dev/null; then
        ok "CRNG + dropbear 就绪（${i}s）"
        READY=1
        break
    fi
    sleep 1
done
[ "$READY" -eq 1 ] || { tail -20 "$QEMU_LOG" 2>/dev/null; die "dropbear 未就绪"; }

# SSH 登录验证
RESULT=$(sshpass -p '' ssh -p 5555 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    root@127.0.0.1 'id; uname -a' 2>&1 || true)

if echo "$RESULT" | grep -q 'uid=0(root)'; then
    ok "SSH 登录成功，root shell"
    echo "$RESULT" | grep 'uid=' | head -1
    echo "$RESULT" | grep 'Linux' | head -1
else
    echo "$RESULT" | tail -5
    die "SSH 登录失败"
fi

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} ✅ 环境搭建完成，SSH 远程登录验证通过 ${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo "日常使用："
echo "  启动: qemu-system-arm -M vexpress-a9 -smp 4 -m 512M \\"
echo "    -kernel $ZIMAGE -dtb $DTB -initrd initramfs.cpio.gz \\"
echo "    -append console=ttyAMA0 \\"
echo "    -net nic,model=lan9118 -net user,hostfwd=tcp:127.0.0.1:5555-:22 \\"
echo "    -device virtio-rng-device -nographic"
echo "  登录: ssh -p 5555 root@127.0.0.1（空口令）"
