#!/usr/bin/env bash
# 07-alu32-ptr-truncation: 32-bit 指针截断
#
# 对应文档 Section 3.2.1 (32-bit vs 64-bit 的区别)
#
# 对比:
#   truncation_bad.bpf.o  → 指针截断为 u32 → Verifier 拒绝 (type=scalar)
#   truncation_good.bpf.o → 64-bit 全程保留 → Verifier 通过

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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

# Step 2: 字节码对比
echo "=========================================="
echo "  Step 2: 字节码对比"
echo "=========================================="

section "bad: 指针经过 u32 截断"
warn "关键: data 被 cast 为 u32 (32-bit)，高 32 位丢失"
warn "转回 void* 后 Verifier 看到 SCALAR_VALUE，不是 PTR_TO_PACKET"
echo ""
llvm-objdump -d truncation_bad.bpf.o | head -25
echo ""

section "good: 64-bit 全程保留指针类型"
warn "data 直接赋值给 struct ethhdr *，类型保持 PTR_TO_PACKET"
echo ""
llvm-objdump -d truncation_good.bpf.o | head -25
echo ""

# Step 3: 加载测试
echo "=========================================="
echo "  Step 3: Verifier 加载测试 (需要 root)"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    warn "非 root 用户，跳过"
    warn "运行 'sudo bash $0'"
    echo ""
    exit 0
fi

if ! command -v bpftool &>/dev/null; then
    warn "bpftool 未安装，跳过"
    exit 0
fi

# Case 1: bad
unset ret || true
section "Case 1: truncation_bad (u32 截断)"
warn "预期: Verifier 报 'type=scalar expected=ptr'"
echo ""
sudo rm -f /sys/fs/bpf/truncation_bad 2>/dev/null
verify_log=$(mktemp)
bpftool prog load truncation_bad.bpf.o /sys/fs/bpf/truncation_bad \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -iE 'scalar|ptr|invalid|type|R[0-9]' "$verify_log" || tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    warn "加载成功 (意外)"
    sudo rm -f /sys/fs/bpf/truncation_bad 2>/dev/null
else
    info "加载失败 ✓ — 指针截断为 u32 后丢失 PTR_TO_PACKET 类型"
    warn "  Verifier 追踪: data (PTR_TO_PACKET) → u32 截断 → SCALAR_VALUE"
    warn "  SCALAR_VALUE 不能做指针解引用 → 拒绝"
fi

# Case 2: good
unset ret || true
section "Case 2: truncation_good (64-bit 保留)"
warn "预期: 加载成功"
echo ""
sudo rm -f /sys/fs/bpf/truncation_good 2>/dev/null
verify_log=$(mktemp)
bpftool prog load truncation_good.bpf.o /sys/fs/bpf/truncation_good \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ — PTR_TO_PACKET 类型全程保留"
    sudo rm -f /sys/fs/bpf/truncation_good 2>/dev/null
else
    warn "加载失败 (意外)"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. BPF_ALU (32-bit) 操作自动零扩展到 64-bit"
warn "  2. 对指针做 32-bit 操作 = 丢失高 32 位 = 指针损坏"
warn "  3. Verifier 追踪类型: PTR_TO_PACKET 经 u32 截断 → SCALAR_VALUE"
warn "  4. SCALAR_VALUE 不能解引用 → Verifier 拒绝"
warn "  5. 始终用 void */u64 操作指针，不要用 u32"
