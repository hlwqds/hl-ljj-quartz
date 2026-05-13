#!/usr/bin/env bash
# 04-stack-workaround: 栈限制对比演示
#
# 对应文档 Section 4.1 - 栈空间限制：512 字节
#
# 对比:
#   stack_overflow_fail.bpf.c   → 编译期拒绝: stack limit exceeded
#   percpu_vstack.bpf.o         → Per-CPU Map 存数据，编译+加载通过

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
echo "  Step 1: 编译"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true

section "对照组: 栈上 600 字节 (预期编译失败)"
if clang -O2 -target bpf -g -Wall -c stack_overflow_fail.bpf.c -o stack_overflow_fail.bpf.o 2>&1; then
    error "意外: 编译通过了!"
else
    info "编译失败 ✓ — clang 在编译期检测到栈超限"
    warn "关键错误信息:"
    clang -O2 -target bpf -g -Wall -c stack_overflow_fail.bpf.c -o /dev/null 2>&1 | head -3
    warn ""
    warn "clang 21+ 会在编译期检查 BPF 栈大小 (之前只有 Verifier 在加载时检查)"
    warn "错误提示的解决方案: 'move large on stack variables into BPF per-cpu array map'"
    warn "这正是我们 Per-CPU Map 方案要做的事!"
fi

echo ""

section "Per-CPU Map 方案 (预期编译+加载通过)"
if clang -O2 -target bpf -g -Wall -c percpu_vstack.bpf.c -o percpu_vstack.bpf.o 2>&1; then
    info "编译成功 ✓ — 数据在 Map 中，栈使用远小于 512 字节"
else
    error "编译失败"
fi
echo ""

# Step 2: 栈帧大小对比
echo "=========================================="
echo "  Step 2: Per-CPU Map 方案栈帧分析"
echo "=========================================="

if [[ -f percpu_vstack.bpf.o ]]; then
    section "字节码中的栈访问"
    llvm-objdump -d percpu_vstack.bpf.o | grep 'r10' || echo "  (无 r10 栈访问)"
    echo ""
    warn "注意: 栈帧很小 (几十字节)，大缓冲区在 Per-CPU Map 中"
fi

# Step 3: 加载测试（需要 root）
echo ""
echo "=========================================="
echo "  Step 3: 加载测试 (需要 root)"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    warn "非 root 用户，跳过加载测试"
    warn "运行 'sudo bash $0' 进行完整测试"
    echo ""
    exit 0
fi

if ! command -v bpftool &>/dev/null; then
    warn "bpftool 未安装，跳过"
    exit 0
fi

if [[ ! -f percpu_vstack.bpf.o ]]; then
    exit 0
fi

sudo rm -f /sys/fs/bpf/percpu_vstack 2>/dev/null

section "加载 Per-CPU Map 方案"
verify_log=$(mktemp)
bpftool prog load percpu_vstack.bpf.o /sys/fs/bpf/percpu_vstack type xdp \
    > "$verify_log" 2>&1 || load_result=$?
load_result=${load_result:-0}
tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $load_result -eq 0 ]]; then
    info "Verifier 通过 ✓ — Per-CPU Map 绕过栈限制"
    sudo rm -f /sys/fs/bpf/percpu_vstack 2>/dev/null
else
    warn "加载失败 — 检查上面的 Verifier 日志"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 修改 stack_overflow_fail.bpf.c 中 big_buf 为 512，看编译是否通过"
warn "  2. 修改 percpu_vstack.bpf.c 中 LARGE_BUF_SIZE 为 8192，验证 Map 方案不受限"
warn "  3. 试试 clang 提示的 -mllvm -bpf-stack-size 参数提高栈限制"
