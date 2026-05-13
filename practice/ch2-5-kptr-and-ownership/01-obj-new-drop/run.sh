#!/usr/bin/env bash
# 01-obj-new-drop: bpf_obj_new/drop 堆分配与泄漏检测
#
# 对应文档 Section 3 + Section 7.1
#
# 对比:
#   basic_alloc.bpf.o  → 分配 + 释放，Verifier 通过
#   leak_fail.bpf.o    → 分配不释放，Verifier 拒绝 "Unreleased reference"

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
warn()  { echo -e "${YELLOW}[NOTE]${NC} $*"; }
section() { echo -e "\n${CYAN}--- $* ---${NC}"; }

# Step 1: 编译
echo "=========================================="
echo "  Step 1: 编译两个程序"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true

section "basic_alloc.bpf.c (正确: 分配 + 释放)"
if clang -O2 -target bpf -g -Wall -c basic_alloc.bpf.c -o basic_alloc.bpf.o 2>&1; then
    info "编译成功 ✓"
else
    error "编译失败"
fi
echo ""

section "leak_fail.bpf.c (故意泄漏: 分配不释放)"
if clang -O2 -target bpf -g -Wall -c leak_fail.bpf.c -o leak_fail.bpf.o 2>&1; then
    info "编译成功 (Verifier 在加载时才检查所有权)"
else
    error "编译失败"
fi
echo ""

# Step 2: Verifier 验证（需要 root）
echo "=========================================="
echo "  Step 2: Verifier 所有权检查 (需要 root)"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    warn "非 root 用户，跳过 Verifier 测试"
    warn "运行 'sudo bash $0' 进行完整测试"
    warn ""
    warn "预期结果:"
    warn "  basic_alloc.bpf.o  → Verifier 通过 (new + drop 配对)"
    warn "  leak_fail.bpf.o    → Verifier 拒绝 'Unreleased reference'"
    echo ""
    exit 0
fi

if ! command -v bpftool &>/dev/null; then
    warn "bpftool 未安装"
    exit 0
fi

section "加载 basic_alloc (预期通过)"
verify_log=$(mktemp)
bpftool prog load basic_alloc.bpf.o /sys/fs/bpf/basic_alloc \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "Verifier 通过 ✓ — 每个 bpf_obj_new 都有对应的 bpf_obj_drop"
    sudo rm -f /sys/fs/bpf/basic_alloc 2>/dev/null
else
    warn "加载失败 — 检查上面日志"
fi
echo ""

section "加载 leak_fail (预期拒绝)"
verify_log=$(mktemp)
bpftool prog load leak_fail.bpf.o /sys/fs/bpf/leak_fail \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
# 显示 Verifier 日志中 ref_obj_id 和 Unreleased reference 行
grep -E 'ref_obj_id|Unreleased reference|EXIT instruction' "$verify_log" || tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -ne 0 ]]; then
    info "Verifier 拒绝 ✓ — 符合预期"
    info "关键错误: 'Unreleased reference' (引用泄漏)"
else
    error "意外: Verifier 竟然通过了!"
fi
sudo rm -f /sys/fs/bpf/leak_fail 2>/dev/null

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 在 leak_fail.bpf.c 中添加 bpf_obj_drop(d)，观察 Verifier 通过"
warn "  2. 尝试 double free: 在 basic_alloc 中调用两次 bpf_obj_drop(d)"
warn "  3. 修改结构体大小，观察 bpf_obj_new 的分配限制"
