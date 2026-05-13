#!/usr/bin/env bash
# 03-tail-calls: Tail Call 多阶段管线
#
# 对应文档 Section 4
#
# 三个 XDP 程序通过 BPF_MAP_TYPE_PROG_ARRAY + bpf_tail_call 串联

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
echo "  Step 1: 编译三个阶段"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true
make
echo ""

# Step 2: 字节码分析
echo "=========================================="
echo "  Step 2: 字节码中的 Tail Call 指令"
echo "=========================================="

section "stage0: bpf_tail_call 跳转"
warn "imm 字段 = 0 (BPF_FUNC_tail_call), off 字段 = Map 索引"
echo ""
llvm-objdump -d stage0.bpf.o | grep -E 'call|tail' | head -10
echo ""

section "stage1: bpf_tail_call 跳转"
llvm-objdump -d stage1.bpf.o | grep -E 'call|tail' | head -10
echo ""

section "stage2: 最终决策 (无 tail call)"
llvm-objdump -d stage2.bpf.o | grep -E 'call|tail|exit' | head -10
echo ""

# Step 3: 加载 + Tail Call 测试（需要 root）
echo "=========================================="
echo "  Step 3: 加载管线 (需要 root)"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    warn "非 root 用户，跳过"
    warn "运行 'sudo bash $0'"
    warn ""
    warn "Tail Call 需要将多个程序加载到 PROG_ARRAY Map:"
    warn "  1. 加载 stage0.bpf.o → 注册到 jump_table[0]"
    warn "  2. 加载 stage1.bpf.o → 注册到 jump_table[1]"
    warn "  3. 加载 stage2.bpf.o → 注册到 jump_table[2]"
    warn "  4. 挂载 XDP 到网卡 → 流量依次经过 stage0→1→2"
    echo ""
    exit 0
fi

if ! command -v bpftool &>/dev/null; then
    warn "bpftool 未安装"
    exit 0
fi

PIN="/sys/fs/bpf/tail_call_demo"
sudo rm -rf "$PIN" 2>/dev/null
sudo mkdir -p "$PIN"

section "创建 Prog Array Map"
bpftool map create "$PIN/jump_table" type prog_array key 4 value 4 entries 3 name jump_table 2>&1 || true
echo ""

section "加载 stage0 → jump_table[0]"
verify_log=$(mktemp)
bpftool prog load stage0.bpf.o "$PIN/stage0" type xdp \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "stage0 加载成功 ✓"
    # 注册到 jump_table[0]
    bpftool map update pinned "$PIN/jump_table" key hex 0 0 0 0 value id $(bpftool prog show -p pinned "$PIN/stage0" 2>/dev/null | head -1) 2>/dev/null || true
else
    warn "stage0 加载失败"
    sudo rm -rf "$PIN" 2>/dev/null
    exit 0
fi

section "加载 stage1 → jump_table[1]"
verify_log=$(mktemp)
bpftool prog load stage1.bpf.o "$PIN/stage1" type xdp \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "stage1 加载成功 ✓"
    bpftool map update pinned "$PIN/jump_table" key hex 1 0 0 0 value id $(bpftool prog show -p pinned "$PIN/stage1" 2>/dev/null | head -1) 2>/dev/null || true
else
    warn "stage1 加载失败"
fi

section "加载 stage2 → jump_table[2]"
verify_log=$(mktemp)
bpftool prog load stage2.bpf.o "$PIN/stage2" type xdp \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "stage2 加载成功 ✓"
    bpftool map update pinned "$PIN/jump_table" key hex 2 0 0 0 value id $(bpftool prog show -p pinned "$PIN/stage2" 2>/dev/null | head -1) 2>/dev/null || true
else
    warn "stage2 加载失败"
fi

section "Prog Array Map 内容"
bpftool map dump pinned "$PIN/jump_table" 2>/dev/null || true
echo ""

# 清理
sudo rm -rf "$PIN" 2>/dev/null

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "Tail Call 要点:"
warn "  - bpf_tail_call 不返回，执行权完全转移"
warn "  - 跳转失败返回 -ENOENT，调用者继续执行"
warn "  - 最多 33 层嵌套 (BPF_MAX_TAIL_CALLS)"
warn "  - 栈被清空重建，不共享 512B 限制"
