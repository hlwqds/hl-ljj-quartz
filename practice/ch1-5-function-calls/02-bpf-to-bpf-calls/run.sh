#!/usr/bin/env bash
# 02-bpf-to-bpf-calls: 子函数调用 + 栈共享陷阱
#
# 对应文档 Section 3
#
# 对比:
#   bpf_call_demo.bpf.o        → inline + static 子函数，正常编译
#   stack_overflow.bpf.o       → kprobe 类型，adaptive private stack，可以加载
#   stack_overflow_nopriv.bpf.o → cgroup_skb 类型，NO_PRIV_STACK，加载失败

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

section "bpf_call_demo.bpf.c (正常: inline + static)"
if clang -O2 -target bpf -g -Wall -c bpf_call_demo.bpf.c -o bpf_call_demo.bpf.o 2>&1; then
    info "编译成功 ✓"
else
    error "编译失败"
fi
echo ""

section "stack_overflow.bpf.c (kprobe: adaptive private stack)"
warn "主函数 300B + 子函数 250B = 550B > 512B"
warn "但 kprobe 启用 PRIV_STACK_ADAPTIVE，每个 subprog 独立栈帧"
echo ""
if clang -O2 -target bpf -g -Wall -c stack_overflow.bpf.c -o stack_overflow.bpf.o 2>&1; then
    info "编译成功 ✓ (kprobe 类型不检查累加栈大小)"
else
    error "编译失败"
fi
echo ""

section "stack_overflow_nopriv.bpf.c (cgroup_skb: NO_PRIV_STACK)"
warn "同样的代码，但 cgroup_skb 不启用 adaptive private stack"
warn "预期: verifier 报错 combined stack size ... Too large"
echo ""
if clang -O2 -target bpf -g -Wall -c stack_overflow_nopriv.bpf.c -o stack_overflow_nopriv.bpf.o 2>&1; then
    info "编译成功 ✓"
else
    error "编译失败"
fi
echo ""

# Step 2: 字节码分析
echo "=========================================="
echo "  Step 2: BPF-to-BPF Call 字节码"
echo "=========================================="

section "inline vs 非 inline 对比"
warn "__always_inline: 代码展开，无 BPF_CALL 指令"
warn "static 非 inline: 生成 BPF_CALL 指令"
echo ""
info "bpf_call_demo 字节码中的 call 指令:"
llvm-objdump -d bpf_call_demo.bpf.o | grep -E 'call|helper' | head -10
echo ""

section "stack_overflow 栈帧分配"
info "stack_overflow.bpf.o (kprobe):"
llvm-objdump -d stack_overflow.bpf.o | grep -E 'r[0-9] \+=|call' | head -10
echo ""
info "stack_overflow_nopriv.bpf.o (cgroup_skb):"
llvm-objdump -d stack_overflow_nopriv.bpf.o | grep -E 'r[0-9] \+=|call' | head -10
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

section "加载 bpf_call_demo"
sudo rm -f /sys/fs/bpf/bpf_call_demo 2>/dev/null
verify_log=$(mktemp)
bpftool prog load bpf_call_demo.bpf.o /sys/fs/bpf/bpf_call_demo type xdp \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓"
    sudo rm -f /sys/fs/bpf/bpf_call_demo 2>/dev/null
else
    warn "加载失败"
fi

section "加载 stack_overflow (kprobe: adaptive private stack)"
sudo rm -f /sys/fs/bpf/stack_overflow 2>/dev/null
verify_log=$(mktemp)
bpftool prog load stack_overflow.bpf.o /sys/fs/bpf/stack_overflow \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ (adaptive private stack 生效，每个 subprog 独立栈帧)"
    sudo rm -f /sys/fs/bpf/stack_overflow 2>/dev/null
else
    warn "加载失败 (意外: kprobe 应该允许)"
fi

section "加载 stack_overflow_nopriv (cgroup_skb: NO_PRIV_STACK)"
sudo rm -f /sys/fs/bpf/stack_nopriv 2>/dev/null
verify_log=$(mktemp)
bpftool prog load stack_overflow_nopriv.bpf.o /sys/fs/bpf/stack_nopriv \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -E 'combined stack|Too large|processed' "$verify_log" || tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    warn "加载成功 (意外: cgroup_skb 应该拒绝累加栈 > 512B)"
    sudo rm -f /sys/fs/bpf/stack_nopriv 2>/dev/null
else
    info "加载失败 ✓ (NO_PRIV_STACK 模式: combined stack size 累加检查)"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 将 parse_header 从 __always_inline 改为 static，对比字节码差异"
warn "  2. 修改 stack_overflow_nopriv.bpf.c 使单个 subprog > 512B，观察 kprobe 也失败"
warn "  3. 用 Per-CPU Map 代替栈变量，绕过 512B 限制"
