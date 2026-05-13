#!/usr/bin/env bash
# 06-register-calling-convention: 寄存器调用约定 & 5 参数限制
#
# 对应文档 Section 2.2 (寄存器详解) + Section 4.2 (参数限制)
#
# 展示:
#   1. BPF 子函数 6 参数 → clang 编译错误 (R1-R5 只有 5 个)
#   2. struct 包装参数 → 编译 + 加载成功
#   3. 字节码中 R6-R9 callee-saved 寄存器的使用

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

# Step 1: 编译测试
echo "=========================================="
echo "  Step 1: 5 参数限制测试"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true
echo ""

section "bad: 6 个参数的全局函数 (预期编译失败)"
warn "BPF ISA 只有 R1-R5 五个参数寄存器"
warn "全局函数 (非 static) 不能被 clang 内联，暴露参数数量限制"
echo ""
if clang -O2 -target bpf -g -Wall -c param_limit_bad.bpf.c -o param_limit_bad.bpf.o 2>&1; then
    warn "编译成功 (意外 — clang 版本可能不检查参数数量)"
else
    info "编译失败 ✓ — clang: 'stack arguments are not supported'"
    warn ""
    warn "根本原因:"
    warn "  eBPF 通过 R1-R5 传递参数 (只有 5 个寄存器)"
    warn "  第 6 个参数无法通过寄存器传递，BPF 不支持栈传参"
    warn "  跨架构兼容性权衡: x86_64 有 6 个, ARM64 有 8 个"
    warn "  5 是所有主流架构的最大公约数"
fi
echo ""

section "good: struct 包装参数 (预期编译成功)"
if clang -O2 -target bpf -g -Wall -c param_limit_good.bpf.c -o param_limit_good.bpf.o 2>&1; then
    info "编译成功 ✓ — struct 指针只占 R1 一个寄存器"
else
    warn "编译失败 (意外)"
fi
echo ""

# Step 2: 字节码中的寄存器使用
echo "=========================================="
echo "  Step 2: 寄存器使用分析"
echo "=========================================="

if [[ ! -f param_limit_good.bpf.o ]]; then
    warn "param_limit_good.bpf.o 不存在，跳过字节码分析"
    exit 0
fi

section "param_limit_good 字节码 — 观察 R6-R9 使用"
warn "R6-R9 是 callee-saved: helper 调用后值不变"
warn "编译器将需要跨调用保存的值放在 R6-R9，避免 spill 到 512B 栈"
echo ""
llvm-objdump -d param_limit_good.bpf.o
echo ""

# 高亮 R6-R9 的使用
echo "---"
info "R6-R9 (callee-saved) 使用:"
llvm-objdump -d param_limit_good.bpf.o | grep -E '\br[6-9]\b' --color=always || echo "  (编译器可能优化掉了跨调用保存)"
echo ""
info "R1-R5 (caller-saved / 参数传递):"
llvm-objdump -d param_limit_good.bpf.o | grep -E '\bcall\b' --color=always || echo "  (无 helper 调用)"
echo ""

# Step 3: 加载测试 (需要 root)
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
    warn "bpftool 未安装，跳过"
    exit 0
fi

section "加载 param_limit_good"
sudo rm -f /sys/fs/bpf/param_limit_good 2>/dev/null
verify_log=$(mktemp)
bpftool prog load param_limit_good.bpf.o /sys/fs/bpf/param_limit_good \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓"
    sudo rm -f /sys/fs/bpf/param_limit_good 2>/dev/null
else
    warn "加载失败 (意外)"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. BPF 只有 R1-R5 五个参数寄存器 → 子函数最多 5 个参数"
warn "  2. 超过 5 个参数用 struct 包装 → 只占 1 个寄存器"
warn "  3. R6-R9 是 callee-saved → helper 调用后值不变"
warn "  4. R10 是只读栈指针 → 永远指向栈帧底部"
warn "  5. clang 会自动选择 R6-R9 保存跨调用存活的值"
