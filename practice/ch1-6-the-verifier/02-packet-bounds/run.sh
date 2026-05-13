#!/usr/bin/env bash
# 02-packet-bounds: XDP 包越界访问
#
# 对应文档 Section 6.3 + Section 4.1
#
# 对比:
#   bounds_bad.bpf.o  → 不检查 data_end，Verifier 拒绝
#   bounds_good.bpf.o → 完整 L2→L3→L4 边界检查链

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

# Step 2: 字节码分析
echo "=========================================="
echo "  Step 2: 字节码分析"
echo "=========================================="

section "bad: 无边界检查"
warn "直接从 ctx->data 偏移 12 读取 h_proto，没有与 data_end 比较"
echo ""
llvm-objdump -d bounds_bad.bpf.o | grep -E 'r[0-9].*data|call|if|<bounds' | head -10
echo ""

section "good: 三层边界检查"
warn "每个 (header + 1) > data_end 检查都在 Verifier 中建立安全边界"
echo ""
llvm-objdump -d bounds_good.bpf.o | grep -E 'if|goto|<bounds' | head -10
echo ""

# Step 3: 加载测试
echo "=========================================="
echo "  Step 3: Verifier 加载测试 (需要 root)"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    warn "非 root 用户，跳过"
    warn "运行 'sudo bash $0'"
    exit 0
fi

if ! command -v bpftool &>/dev/null; then
    warn "bpftool 未安装"
    exit 0
fi

# Case 1: bad
section "Case 1: bounds_bad (不检查 data_end)"
warn "预期: Verifier 报 'invalid access to packet' 或 'R1 offset is outside'"
echo ""
sudo rm -f /sys/fs/bpf/bounds_bad 2>/dev/null
verify_log=$(mktemp)
bpftool prog load bounds_bad.bpf.o /sys/fs/bpf/bounds_bad \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -iE 'invalid|access|packet|outside|bounds|R1|data_end' "$verify_log" || tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    warn "加载成功 (意外)"
    sudo rm -f /sys/fs/bpf/bounds_bad 2>/dev/null
else
    info "加载失败 ✓ — Verifier 无法证明包数据访问在合法范围内"
    warn "核心原因: data 指针只标记为 PTR_TO_PACKET"
    warn "          没有 data_end 边界检查 → Verifier 不知道偏移 12 是否安全"
fi

# Case 2: good
unset ret || true
section "Case 2: bounds_good (完整边界检查链)"
warn "预期: 加载成功"
echo ""
sudo rm -f /sys/fs/bpf/bounds_good 2>/dev/null
verify_log=$(mktemp)
bpftool prog load bounds_good.bpf.o /sys/fs/bpf/bounds_good \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ — 每层边界检查为 Verifier 建立了安全范围"
    sudo rm -f /sys/fs/bpf/bounds_good 2>/dev/null
else
    warn "加载失败 (意外)"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 在 good 版本中注释掉 L3 检查，观察 L4 访问是否被 Verifier 拒绝"
warn "  2. 用 bpf_htons(0x0800) 替代硬编码 0x0800，对比字节码差异"
warn "  3. 尝试访问 tcp->dest 之前只检查 ip 而不检查 tcp 的边界"
