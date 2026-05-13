#!/usr/bin/env bash
# 02-core-read: BPF_CORE_READ 跨版本读取内核结构体
#
# 对应文档 Section 4 (BTF_CORE_READ 与 CO-RE 编程 API)
#
# 本脚本展示 CO-RE 的核心能力:
#   1. 编译 BPF 程序 (使用 vmlinux.h + BPF_CORE_READ)
#   2. 查看编译产物中的 CO-RE 重定位记录
#   3. 加载程序 (libbpf 自动修正偏移量)
#   4. 触发 syscalls，观察 Ring Buffer 事件
#
# CO-RE 三阶段:
#   编译时: clang 生成 BTF 重定位记录
#   加载时: libbpf 对比目标 BTF，修正偏移量
#   运行时: 零额外开销

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[NOTE]${NC} $*"; }
section() { echo -e "\n${CYAN}--- $* ---${NC}"; }

# Step 1: 编译
echo "=========================================="
echo "  Step 1: 编译"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true
make 2>&1
echo ""

if [[ ! -f core_read.bpf.o ]]; then
    warn "编译失败"
    exit 1
fi
info "编译成功 ✓"

# Step 2: 查看 CO-RE 重定位记录
section "Step 2: CO-RE 重定位记录"
warn "clang -g 生成 BTF 重定位记录"
warn "每条记录记录了: 访问哪个结构体的哪个字段，编译时偏移量是多少"
echo ""

if command -v bpftool &>/dev/null; then
    echo "BTF 重定位记录:"
    bpftool btf dump file core_read.bpf.o 2>/dev/null \
        | grep -A 2 "field" | head -30
    echo ""

    warn "这些记录在 libbpf 加载时会与目标内核 BTF 对比"
    warn "偏移量不同时，libbpf 自动修正字节码中的偏移量"
fi

# Step 3: 加载
echo "=========================================="
echo "  Step 3: 加载 (需要 root)"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    warn "非 root 用户，跳过"
    warn "运行 'sudo bash $0'"
    exit 0
fi

if ! command -v bpftool &>/dev/null; then
    warn "bpftool 未安装，跳过"
    exit 0
fi

sudo rm -f /sys/fs/bpf/core_read 2>/dev/null
verify_log=$(mktemp)
bpftool prog load core_read.bpf.o /sys/fs/bpf/core_read \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""

if [[ $ret -ne 0 ]]; then
    warn "加载失败，跳过"
    exit 0
fi

info "加载成功 ✓"

# Step 4: 触发 syscalls
section "Step 4: 触发 open 调用"
warn "BPF 程序通过 BPF_CORE_READ 读取 task_struct 字段"
warn "偏移量已在加载时自动修正"
echo ""

for i in $(seq 1 3); do
    cat /proc/loadavg > /dev/null 2>&1 || true
done
echo "  (3 次 open 完成)"
echo ""

# Step 5: 查看统计
section "Step 5: Ring Buffer 事件"
warn "BPF_CORE_READ 读取的结果:"
echo ""

# Ring Buffer 需要用户态程序读取，这里用 bpftool 查看程序信息
bpftool prog show name on_open 2>/dev/null || true
echo ""

section "CO-RE 重定位验证"
warn "查看已加载程序的字节码中的偏移量"
warn "对比编译时和加载后的偏移量差异 → 这就是 CO-RE 的魔法"
echo ""

PROG_ID=$(bpftool prog show name on_open 2>/dev/null | grep -oP 'id \K[0-9]+' | head -1)
if [[ -n "$PROG_ID" ]]; then
    bpftool prog dump xlated id "$PROG_ID" 2>/dev/null | head -20
else
    warn "无法获取程序 ID"
fi

# 清理
sudo rm -f /sys/fs/bpf/core_read 2>/dev/null

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. BPF_CORE_READ(task, pid) → clang 生成 CO-RE 重定位记录"
warn "  2. libbpf 加载时读取 /sys/kernel/btf/vmlinux"
warn "  3. libbpf 对比重定位记录与目标 BTF，修正偏移量"
warn "  4. 运行时零额外开销 — 偏移量修正只发生在加载阶段"
warn "  5. 编译一次，所有支持 BTF 的内核都能运行 (CO-RE)"
