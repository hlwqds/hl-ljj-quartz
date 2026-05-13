#!/usr/bin/env bash
# 03-bounded-loops: 有界循环 vs 无界循环验证
#
# 对应文档 Section 4.4
#
# 关键认知:
#   clang 编译两种循环都会成功（生成 BPF 字节码）
#   Verifier 在加载时才会拒绝无界循环
#
# 本脚本:
# 1. 编译两种循环
# 2. 对比字节码差异
# 3. 尝试加载，展示 Verifier 的拒绝信息

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
echo "  Step 1: 编译两种循环"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true

info "编译有界循环 (valid_loop.bpf.c)..."
if clang -O2 -target bpf -g -Wall -c valid_loop.bpf.c -o valid_loop.bpf.o 2>&1; then
    info "  编译成功 ✓"
else
    error "  编译失败 ✗"
    exit 1
fi

info "编译无界循环 (invalid_loop.bpf.c)..."
if clang -O2 -target bpf -g -Wall -c invalid_loop.bpf.c -o invalid_loop.bpf.o 2>&1; then
    warn "  编译成功 (字节码生成不检查循环边界!)"
else
    error "  编译失败 ✗"
fi
echo ""

# Step 2: 字节码对比
echo "=========================================="
echo "  Step 2: 字节码对比"
echo "=========================================="

section "有界循环字节码"
valid_count=$(llvm-objdump -d valid_loop.bpf.o | grep -cE '^\s+[0-9]+:' || echo "0")
info "指令数: $valid_count"
llvm-objdump -d valid_loop.bpf.o | head -30
if [[ $valid_count -gt 30 ]]; then
    warn "... (共 $valid_count 条，已截断)"
fi

echo ""

section "无界循环字节码"
invalid_count=$(llvm-objdump -d invalid_loop.bpf.o | grep -cE '^\s+[0-9]+:' || echo "0")
info "指令数: $invalid_count"
llvm-objdump -d invalid_loop.bpf.o | head -30
if [[ $invalid_count -gt 30 ]]; then
    warn "... (共 $invalid_count 条，已截断)"
fi

echo ""

# Step 3: Verifier 验证（需要 root + bpftool）
echo "=========================================="
echo "  Step 3: Verifier 验证 (需要 root)"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    warn "非 root 用户，跳过 Verifier 测试"
    warn "运行 'sudo bash $0' 进行完整测试"
    warn ""
    warn "预期结果:"
    warn "  valid_loop.bpf.o   → Verifier 检查通过或因包访问越界拒绝"
    warn "  invalid_loop.bpf.o → Verifier 路径爆炸拒绝 (-E2BIG)"
    echo ""
    exit 0
fi

if ! command -v bpftool &>/dev/null; then
    warn "bpftool 未安装，跳过加载测试"
    exit 0
fi

# 清理残留
sudo rm -f /sys/fs/bpf/valid_loop /sys/fs/bpf/invalid_loop 2>/dev/null

section "加载有界循环程序"
warn "bpftool 输出 (包含 Verifier 日志):"
echo "---"
bpftool prog load valid_loop.bpf.o /sys/fs/bpf/valid_loop type xdp 2>&1 || load_valid=$?
load_valid=${load_valid:-0}
echo "---"
echo ""
if [[ $load_valid -eq 0 ]]; then
    info "  Verifier 通过 ✓ — 程序已加载"
    bpftool prog unload pinned /sys/fs/bpf/valid_loop 2>/dev/null || true
else
    warn "  加载失败 (exit code: $load_valid)"
    warn "  分析: 即使有界循环通过了 Verifier 的循环检查，"
    warn "  包数据访问仍需正确的边界检查 (见 Section 5.1)"
fi
sudo rm -f /sys/fs/bpf/valid_loop 2>/dev/null

echo ""

section "加载无界循环程序"
warn "预期: Verifier 因路径爆炸拒绝!"
echo "---"
verify_log=$(mktemp)
bpftool prog load invalid_loop.bpf.o /sys/fs/bpf/invalid_loop type xdp > "$verify_log" 2>&1 || load_invalid=$?
load_invalid=${load_invalid:-0}
# Verifier 日志可能非常长 (MB 级)，只显示开头和结尾
head -20 "$verify_log"
echo "  ... (省略中间的路径展开日志) ..."
tail -10 "$verify_log"
rm -f "$verify_log"
echo "---"
echo ""
if [[ $load_invalid -eq 0 ]]; then
    warn "  意外: Verifier 竟然通过了! (内核版本可能支持更灵活的循环)"
    bpftool prog unload pinned /sys/fs/bpf/invalid_loop 2>/dev/null || true
else
    info "  Verifier 拒绝 ✓ — 符合预期"
    info "  关注 Verifier 日志中的:"
    info "    - processed N insns (limit 1000000): 探索的指令数"
    info "    - total_states N / peak_states N: 状态空间大小"
    info "    - 这些数字越大，说明 Verifier 在做路径爆炸分析"
fi
sudo rm -f /sys/fs/bpf/invalid_loop 2>/dev/null

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 修改 valid_loop.bpf.c 中的循环上界 (如改为 1000)，观察指令数变化"
warn "  2. 在 invalid_loop.bpf.c 中添加上限检查 (如 if (n > 64) n = 64)，使其变为合法"
warn "  3. 观察 Verifier 的路径爆炸: 在循环体内添加分支，增加上界，看何时超时"
