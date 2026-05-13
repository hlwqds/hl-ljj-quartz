#!/usr/bin/env bash
# 02-kptr-xchg: bpf_kptr_xchg 原子交换
#
# 对应文档 Section 4
#
# 演示连接跟踪器: bpf_obj_new + bpf_kptr_xchg + bpf_obj_drop

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
echo "  Step 1: 编译连接跟踪器"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true
make
echo ""

# Step 2: 字节码分析
echo "=========================================="
echo "  Step 2: 字节码分析"
echo "=========================================="

section "关键 kfunc 调用"
warn "在字节码中查找 bpf_obj_new / bpf_kptr_xchg / bpf_obj_drop:"
echo ""
llvm-objdump -d conntrack.bpf.o | grep -E 'call' | head -10
echo ""

section "kptr 类型标注"
warn "BTF 中 __kptr 标记让 Verifier 知道这是内核指针:"
echo ""
llvm-objdump -d conntrack.bpf.o | grep -E 'kptr|xchg|spin' | head -10 || true
echo ""

# Step 3: 加载测试（需要 root）
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
    warn "bpftool 未安装"
    exit 0
fi

sudo rm -f /sys/fs/bpf/conntrack 2>/dev/null

section "加载连接跟踪器"
verify_log=$(mktemp)
bpftool prog load conntrack.bpf.o /sys/fs/bpf/conntrack \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "Verifier 通过 ✓ — 所有权正确: new → xchg → drop(old)"
    bpftool prog show name update_conntrack 2>/dev/null || true
    sudo rm -f /sys/fs/bpf/conntrack 2>/dev/null
else
    warn "加载失败 — 检查上面的 Verifier 日志"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 注释掉 bpf_obj_drop(old_conn)，观察 Verifier 报 'Unreleased reference'"
warn "  2. 注释掉 bpf_spin_lock/unlock，观察 Verifier 报错"
warn "  3. 尝试直接赋值 v->conn_ptr = new_conn，观察 Verifier 拒绝"
