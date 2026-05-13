#!/usr/bin/env bash
# 01-helper-functions: Helper Functions 演示
#
# 对应文档 Section 2
#
# 展示多种 Helper 调用及字节码中的 BPF_CALL 指令

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
make
echo ""

# Step 2: 字节码分析
echo "=========================================="
echo "  Step 2: 字节码中的 Helper 调用"
echo "=========================================="

OBJ="helpers_demo.bpf.o"

section "BPF_CALL 指令 (Helper 调用)"
warn "每条 call 指令的 imm 字段 = Helper 函数编号"
echo ""
llvm-objdump -d "$OBJ" | grep -E 'call|helper' | head -15
echo ""

section "Helper 调用寄存器约定 (文档 Section 6.3)"
warn "调用前: R1-R5 = 参数, 调用后: R0 = 返回值, R6-R9 不变"
echo ""
llvm-objdump -d "$OBJ" | head -20
echo ""

# Step 3: 加载测试
echo "=========================================="
echo "  Step 3: 加载测试 (需要 root)"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    warn "非 root 用户，跳过"
    warn "运行 'sudo bash $0'"
    echo ""
    exit 0
fi

if ! command -v bpftool &>/dev/null; then
    warn "bpftool 未安装"
    exit 0
fi

sudo rm -f /sys/fs/bpf/helpers_demo 2>/dev/null

section "加载程序"
verify_log=$(mktemp)
bpftool prog load "$OBJ" /sys/fs/bpf/helpers_demo type kprobe \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓"
    sudo rm -f /sys/fs/bpf/helpers_demo 2>/dev/null
else
    warn "加载失败"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 注释掉 bpf_map_update_elem 的第 4 个参数 (BPF_ANY)，观察 Verifier 报错"
warn "  2. 传递 6 个参数给 Helper，观察 Verifier 报错 (Section 2.4 参数限制)"
warn "  3. 对比字节码中 R1-R5 在 Helper 调用前后的变化"
