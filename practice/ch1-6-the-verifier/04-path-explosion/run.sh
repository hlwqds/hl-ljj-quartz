#!/usr/bin/env bash
# 04-path-explosion: Verifier 路径爆炸
#
# 对应文档 Section 5.2
#
# 对比:
#   explosion_bad.bpf.o  → 15 层嵌套 if，无 early return (2^15 路径)
#   explosion_good.bpf.o → 子函数封装，每个函数独立验证
#
# 注意: kernel 6.19 的 CFG-aware pruning 非常高效，
# 15 层可能不会触发 rejection，但验证时间会有明显差异。

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

# Step 2: 字节码统计
echo "=========================================="
echo "  Step 2: 字节码统计"
echo "=========================================="

bad_insns=$(llvm-objdump -d explosion_bad.bpf.o | grep -cE '^[[:space:]]+[0-9]+:')
good_insns=$(llvm-objdump -d explosion_good.bpf.o | grep -cE '^[[:space:]]+[0-9]+:')

warn "bad  (嵌套 if):   $bad_insns 条指令"
warn "good (子函数):     $good_insns 条指令"
echo ""

# Step 3: 加载测试 + 计时
echo "=========================================="
echo "  Step 3: Verifier 加载测试 + 计时 (需要 root)"
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

# Case 1: bad — 嵌套 if
section "Case 1: explosion_bad (15 层嵌套 if)"
warn "理论路径: 2^15 = 32,768 条"
warn "kernel 6.19 CFG-aware pruning 会大幅减少实际分析路径数"
echo ""
sudo rm -f /sys/fs/bpf/explosion_bad 2>/dev/null
bad_time=$( { time sudo bpftool prog load explosion_bad.bpf.o /sys/fs/bpf/explosion_bad 2>&1; } 2>&1 )
bad_exit=${PIPESTATUS[0]}
echo "$bad_time" | tail -3
echo ""

# 提取 real time
bad_real=$(echo "$bad_time" | grep real | awk '{print $2}')
warn "验证耗时: ${bad_real}"

if [[ $bad_exit -eq 0 ]]; then
    bad_xlated=$(sudo bpftool prog show name explosion_bad 2>&1 | grep 'xlated' | head -1 | grep -oP '\d+B' | head -1)
    warn "xlated: ${bad_xlated}"
    info "加载成功 — CFG-aware pruning 高效处理了嵌套路径"
    warn "在 kernel 5.x 上，同样的代码会触发 'processed N insns' 超限"
    sudo rm -f /sys/fs/bpf/explosion_bad 2>/dev/null
else
    grep -iE 'complexity|limit|processed|too many' "$bad_time" || true
    info "加载失败 ✓ — Verifier 路径数超限"
fi

# Case 2: good — 子函数
unset ret || true
section "Case 2: explosion_good (子函数封装)"
warn "15 个子函数，每个独立验证"
echo ""
sudo rm -f /sys/fs/bpf/explosion_good 2>/dev/null
good_time=$( { time sudo bpftool prog load explosion_good.bpf.o /sys/fs/bpf/explosion_good 2>&1; } 2>&1 )
good_exit=${PIPESTATUS[0]}
echo "$good_time" | tail -3
echo ""

good_real=$(echo "$good_time" | grep real | awk '{print $2}')
warn "验证耗时: ${good_real}"

if [[ $good_exit -eq 0 ]]; then
    good_xlated=$(sudo bpftool prog show name explosion_good 2>&1 | grep 'xlated' | head -1 | grep -oP '\d+B' | head -1)
    warn "xlated: ${good_xlated}"
    info "加载成功 ✓"
    sudo rm -f /sys/fs/bpf/explosion_good 2>/dev/null
else
    warn "加载失败 (意外)"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. 嵌套 if 产生指数级路径: N 层 → 2^N 条"
warn "  2. kernel 6.19 状态剪枝 (State Pruning) 能大幅减少实际分析路径"
warn "     详见: cat cfg-aware-pruning.md"
warn "  3. 但在老内核 (5.x) 上，同样的代码会触发 complexity limit"
warn "  4. 解决方案: 子函数拆分 + early return (Section 8.3)"
warn "  5. 生产建议: 复杂逻辑放 __always_inline 子函数中"
