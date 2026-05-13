#!/usr/bin/env bash
# 08-ptr-arithmetic: 指针算术限制
#
# 对应文档 Section 4.5 (无指针算术限制)
#
# 对比:
#   var_offset_bad.bpf.o  → 运行时变量偏移 → Verifier 无法验证边界
#   var_offset_good.bpf.o → 编译时常量偏移 → Verifier 通过
#
# 核心认知:
#   Verifier 需要在编译时验证每条内存访问都在合法范围内。
#   运行时变量偏移 → Verifier 不知道目标地址 → 拒绝。

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

section "bad: bpf_get_prandom_u32() 生成运行时偏移"
warn "注意 call 指令 (bpf_get_prandom_u32) 和随后的寄存器加法"
echo ""
llvm-objdump -d var_offset_bad.bpf.o | head -30
echo ""

section "good: 编译时常量偏移 (data + 12)"
warn "注意: 偏移 12 直接编码在指令的 imm/off 字段中"
echo ""
llvm-objdump -d var_offset_good.bpf.o | head -20
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
section "Case 1: var_offset_bad (运行时变量偏移)"
warn "预期: Verifier 报 'invalid access to packet' 或 'R1 offset is outside'"
echo ""
sudo rm -f /sys/fs/bpf/var_offset_bad 2>/dev/null
verify_log=$(mktemp)
bpftool prog load var_offset_bad.bpf.o /sys/fs/bpf/var_offset_bad \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -iE 'invalid|access|outside|packet|scalar|offset' "$verify_log" | head -5 || tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    warn "加载成功 (意外 — 内核版本可能支持更灵活的变量偏移)"
    sudo rm -f /sys/fs/bpf/var_offset_bad 2>/dev/null
else
    info "加载失败 ✓ — Verifier 无法验证运行时偏移的边界"
    warn "  原因: n = bpf_get_prandom_u32() 范围是 [0, UMAX]"
    warn "  Verifier 无法证明 data + n + 2 <= data_end"
fi

# Case 2: good
unset ret || true
section "Case 2: var_offset_good (编译时常量偏移)"
warn "预期: 加载成功"
echo ""
sudo rm -f /sys/fs/bpf/var_offset_good 2>/dev/null
verify_log=$(mktemp)
bpftool prog load var_offset_good.bpf.o /sys/fs/bpf/var_offset_good \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ — 常量偏移 12，Verifier 确认 12 + 2 <= 14 <= data_end - data"
    sudo rm -f /sys/fs/bpf/var_offset_good 2>/dev/null
else
    warn "加载失败 (意外)"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. eBPF 只允许编译时已知偏移的指针算术"
warn "  2. sizeof()、offsetof() 是编译时常量 → Verifier 能验证"
warn "  3. 运行时变量偏移 → Verifier 无法确认边界 → 拒绝"
warn "  4. 这个限制防止越界内存访问，是 eBPF 安全模型的核心"
warn "  5. 绕过方案: 先做边界检查 (if data + N > data_end)，再用常量偏移"
