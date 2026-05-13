#!/usr/bin/env bash
# 05-jit-debug: JIT vs 解释执行 对比
#
# 对应文档 Section 6 - JIT 编译原理
#
# 本脚本:
# 1. 分别在 JIT 关闭和开启模式下加载同一个 BPF 程序
# 2. 对比两种模式下的程序信息和字节码
# 3. 展示 JIT 编译后的 x86_64 原生指令
#
# 前提: root 权限 + bpftool

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

cleanup() {
    sudo rm -f /sys/fs/bpf/jit_test 2>/dev/null
    # 恢复 JIT 为原始状态
    if [[ -n "${ORIG_JIT:-}" ]]; then
        echo "$ORIG_JIT" > /proc/sys/net/core/bpf_jit_enable 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
    error "JIT 调试需要 root 权限"
    warn "请运行: sudo bash $0"
    exit 1
fi

if ! command -v bpftool &>/dev/null; then
    error "bpftool 未安装"
    exit 1
fi

# Step 0: 准备程序
echo "=========================================="
echo "  Step 0: 编译 BPF 程序"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true
make
OBJ_FILE="${SCRIPT_DIR}/jit_demo.bpf.o"
BPF_PIN="/sys/fs/bpf/jit_test"
echo ""

# 保存原始 JIT 状态
ORIG_JIT=$(cat /proc/sys/net/core/bpf_jit_enable 2>/dev/null || echo "1")

# Step 1: JIT=1 — 标准模式
echo "=========================================="
echo "  Step 1: JIT 标准模式 (bpf_jit_enable=1)"
echo "=========================================="

# 检查内核是否锁死了 JIT
jit_always_on=$(grep 'CONFIG_BPF_JIT_ALWAYS_ON=y' /boot/config-$(uname -r) 2>/dev/null || true)
jit_default_on=$(grep 'CONFIG_BPF_JIT_DEFAULT_ON=y' /boot/config-$(uname -r) 2>/dev/null || true)

if [[ -n "$jit_always_on" ]]; then
    warn "内核编译选项 CONFIG_BPF_JIT_ALWAYS_ON=y"
    warn "JIT 编译器被锁死为始终启用，无法切换到解释执行模式"
    warn "本脚本将展示: eBPF 字节码 vs x86_64 JIT 原生指令的对比"
    echo ""
elif [[ -n "$jit_default_on" ]]; then
    warn "内核编译选项 CONFIG_BPF_JIT_DEFAULT_ON=y"
    warn "JIT 默认启用，可以尝试关闭 (echo 0 > /proc/sys/net/core/bpf_jit_enable)"
    echo ""
fi

echo 1 > /proc/sys/net/core/bpf_jit_enable 2>/dev/null || true
info "bpf_jit_enable = $(cat /proc/sys/net/core/bpf_jit_enable)"
echo ""

sudo rm -f "$BPF_PIN" 2>/dev/null
verify_log=$(mktemp)
bpftool prog load "$OBJ_FILE" "$BPF_PIN" type xdp \
    > "$verify_log" 2>&1 || load_jit=$?
load_jit=${load_jit:-0}
if [[ $load_jit -ne 0 ]]; then
    tail -5 "$verify_log"
    rm -f "$verify_log"
    error "加载失败"
    exit 1
fi
rm -f "$verify_log"

section "JIT=1 — 程序信息"
bpftool prog show pinned "$BPF_PIN"
echo ""

section "JIT=1 — eBPF 字节码 (xlated)"
bpftool prog dump xlated pinned "$BPF_PIN" 2>/dev/null | head -20
xlated_count=$(bpftool prog dump xlated pinned "$BPF_PIN" 2>/dev/null | grep -cE '^\s+[0-9]+:' || echo "0")
echo ""
info "eBPF 字节码指令数: $xlated_count"
echo ""

section "JIT=1 — x86_64 原生指令 (jited)"
bpftool prog dump jited pinned "$BPF_PIN" 2>/dev/null | head -20
jited_count=$(bpftool prog dump jited pinned "$BPF_PIN" 2>/dev/null | grep -cE '^\s+[0-9]+:' || echo "0")
echo ""
info "JIT 原生指令数: $jited_count"
echo ""

# 清理
bpftool prog unload pinned "$BPF_PIN" 2>/dev/null || true
sudo rm -f "$BPF_PIN" 2>/dev/null

# Step 2: 对比 xlated vs jited
echo "=========================================="
echo "  Step 2: eBPF 字节码 vs x86_64 原生指令 对比"
echo "=========================================="
echo ""

section "eBPF 字节码 (xlated) — 跨平台通用指令"
warn "这些是 Verifier 输出的 eBPF 指令，与 CPU 架构无关:"
echo ""
bpftool prog dump xlated pinned "$BPF_PIN" 2>/dev/null | head -25
echo ""
info "指令数: $xlated_count"
echo ""

section "x86_64 原生指令 (jited) — JIT 编译后的机器码"
warn "JIT 编译器将 eBPF 指令翻译为 CPU 原生指令，直接执行:"
echo ""
bpftool prog dump jited pinned "$BPF_PIN" 2>/dev/null | head -25
echo ""
info "指令数: $jited_count"
echo ""

# 清理
bpftool prog unload pinned "$BPF_PIN" 2>/dev/null || true
sudo rm -f "$BPF_PIN" 2>/dev/null

# Step 3: 对比总结
echo "=========================================="
echo "  Step 3: 映射关系总结"
echo "=========================================="
echo ""
info "  eBPF 指令           | x86_64 映射          | 说明"
echo "  ------------------- | -------------------- | -----------------------------"
echo "  BPF_ALU64 (ADD/SUB) | ADD/SUB r64, r64     | 1:1 直接映射"
echo "  BPF_ALU   (MOV 32)  | MOV r32 + 零扩展     | 1:1 + 隐式清除高 32 位"
echo "  BPF_JMP   (JEQ/JGT) | CMP + Jcc             | 1:2 (比较 + 条件跳转)"
echo "  BPF_CALL  (Helper)  | CALL (保存/恢复寄存器) | 1:N (完整的函数调用约定)"
echo "  BPF_LDX/STX         | MOV [mem], reg        | 1:1 直接映射"
echo ""
warn "关键: JIT 编译是 1:1 或 1:N 映射，消除了解释器的逐条模拟开销"
warn "  文档 Section 6.3: 解释执行 1x, JIT ~10x, 硬件卸载 ~100x+"
echo ""
warn "注意: 内核 6.19+ 不再支持 bpf_jit_enable=0 (JIT 始终启用)"
warn "  旧内核支持: 0=禁用, 1=启用, 2=启用+调试日志"

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 设置 bpf_jit_enable=2，重新运行，用 dmesg 查看 JIT 编译日志"
warn "  2. 对比 xlated 和 jited 输出，找到 1:N 展开的指令 (如 64-bit 加法)"
