#!/usr/bin/env bash
# 03-field-exists: CO-RE vs 硬编码偏移量 + bpf_core_field_exists
#
# 对应文档 Section 4 (BTF_CORE_READ 与 CO-RE 编程 API)
#
# 本脚本对比 bad/good 两种写法:
#   bad:  bpf_probe_read_kernel + 硬编码偏移量 → 换内核就读错数据
#   good: BPF_CORE_READ + bpf_core_field_exists → 跨版本兼容
#
# 核心原理:
#   bad:  编译时确定偏移量 → 换内核后偏移量错误 → 读到垃圾数据
#   good: 编译时生成 CO-RE 重定位 → 加载时 libbpf 修正偏移量 → 正确读取

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[NOTE]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }
section() { echo -e "\n${CYAN}--- $* ---${NC}"; }

# Step 1: 编译
echo "=========================================="
echo "  Step 1: 编译"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true
make 2>&1
echo ""

if [[ ! -f hardcoded_offset_bad.bpf.o ]] || [[ ! -f core_read_good.bpf.o ]]; then
    warn "编译失败"
    exit 1
fi
info "编译成功 ✓ (bad 和 good 都能编译)"

# Step 2: 分析 bad 版本
section "Step 2: 分析 hardcoded_offset_bad"
warn "bad 版本硬编码了偏移量:"
warn "  task->comm 在 offset 556 (5.15 内核的正确值)"
warn "  task->pid 在 offset 944 (5.15 内核的正确值)"
echo ""

warn "当前内核 ($(uname -r)) 的实际偏移量:"
echo ""

# 从 vmlinux.h 找出 comm 和 pid 的实际偏移
COMM_LINE=$(grep -n "char comm\[16\]" vmlinux.h 2>/dev/null | head -1)
if [[ -n "$COMM_LINE" ]]; then
    warn "  comm: $(grep 'char comm' vmlinux.h | head -1)"
fi
PID_LINE=$(grep -n "pid_t pid" vmlinux.h 2>/dev/null | head -1)
if [[ -n "$PID_LINE" ]]; then
    warn "  pid: $(grep 'pid_t pid' vmlinux.h | head -1)"
fi

echo ""
warn "如果偏移量 != 556/944，bad 版本就会读到错误数据!"
echo ""

# Step 3: 加载两个版本
echo "=========================================="
echo "  Step 3: 加载 (需要 root)"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    warn "非 root 用户，跳过"
    warn "运行 'sudo bash $0'"
    exit 0
fi

if ! command -v bpftool &>/dev/null; then
    warn "bpftool 未安装，跳过"
    exit 0
fi

# 加载 bad 版本
sudo rm -f /sys/fs/bpf/field_bad 2>/dev/null
verify_log=$(mktemp)
bpftool prog load hardcoded_offset_bad.bpf.o /sys/fs/bpf/field_bad \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""

if [[ $ret -ne 0 ]]; then
    fail "加载失败"
else
    info "bad 加载成功 (但运行时可能读到错误数据)"
fi

# 加载 good 版本
sudo rm -f /sys/fs/bpf/field_good 2>/dev/null
verify_log=$(mktemp)
bpftool prog load core_read_good.bpf.o /sys/fs/bpf/field_good \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""

if [[ $ret -ne 0 ]]; then
    fail "加载失败 (意外)"
else
    info "good 加载成功 ✓"
    warn "libbpf 已自动修正 CO-RE 偏移量"
fi

# Step 4: 对比字节码
section "Step 4: 字节码对比"
warn "bad: 硬编码偏移量 (编译时确定，换内核不修正)"
warn "good: CO-RE 重定位 (libbpf 加载时修正为当前内核的真实偏移)"
echo ""

if command -v llvm-objdump &>/dev/null; then
    echo "--- bad: hardcoded_offset_bad ---"
    warn "硬编码 comm 偏移量 0x22c (556)，pid 偏移量 0x3b0 (944):"
    llvm-objdump -d hardcoded_offset_bad.bpf.o 2>/dev/null | grep "r1 += 0x22c\|r3 += 0x3b0"
    echo ""

    echo "--- good: core_read_good ---"
    warn "CO-RE 生成 preserve_access_index 指令 (加载时由 libbpf 修正):"
    llvm-objdump -d core_read_good.bpf.o 2>/dev/null | grep -i "preserve\|core" | head -5 || \
    llvm-objdump -d core_read_good.bpf.o 2>/dev/null | grep "r.*+=" | head -5
    echo ""

    echo "--- good: BTF 中的字段偏移 (当前内核真实值) ---"
    COMM_OFF=$(bpftool btf dump file core_read_good.bpf.o 2>/dev/null | grep "'comm'" | grep task_struct -A1 | tail -1 | grep -oP 'bits_offset=\K[0-9]+' || echo "?")
    warn "comm: bits_offset=${COMM_OFF} ($(( ${COMM_OFF:-0} / 8 )) 字节)"
    warn "对比: bad 硬编码 556 字节 → 当前内核实际 $(( ${COMM_OFF:-0} / 8 )) 字节 → bad 读错数据"
fi

# 清理
sudo rm -f /sys/fs/bpf/field_bad /sys/fs/bpf/field_good 2>/dev/null

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. 硬编码偏移量在不同内核上会读到错误数据 (bad)"
warn "  2. BPF_CORE_READ 自动适配字段偏移量 (good)"
warn "  3. bpf_core_field_exists 处理跨版本字段差异"
warn "     有字段 → if(1) 保留分支"
warn "     无字段 → if(0) JIT 消除分支 → 零运行时开销"
warn "  4. CO-RE 的核心: 编译一次，到处运行"
