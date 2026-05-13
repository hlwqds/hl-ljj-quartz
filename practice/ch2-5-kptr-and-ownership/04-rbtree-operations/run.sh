#!/usr/bin/env bash
# 04-rbtree-operations: bpf_rbtree_add 红黑树操作
#
# 对应文档 Section 5.2
#
# 演示: 分配节点 → rbtree_add(自动排序) → 处理错误
#
# 注意: kernel 6.19 + libbpf 1.6 的 BTF 兼容性问题
#       本练习以编译 + BTF 分析为主

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
echo "  Step 1: 编译红黑树程序"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null; make
echo ""

# Step 2: BTF 分析
echo "=========================================="
echo "  Step 2: BTF 类型分析"
echo "=========================================="

section "struct node 与 bpf_rb_node 的 BTF"
warn "bpf_rb_node 是不透明类型 (opaque[4] = 4 个 u64)"
echo ""
bpftool btf dump file rbtree.bpf.o 2>/dev/null | grep -A5 "STRUCT 'node'\|STRUCT 'bpf_rb_node'\|STRUCT 'bpf_rb_root'"
echo ""

section "bpf_rbtree_add_impl 的 kfunc 签名"
warn "第 3 个参数是函数指针: int (*less)(bpf_rb_node*, const bpf_rb_node*)"
echo ""
bpftool btf dump file rbtree.bpf.o 2>/dev/null | grep -B2 -A8 "bpf_rbtree_add_impl"
echo ""

# Step 3: 字节码分析
echo "=========================================="
echo "  Step 3: 字节码分析"
echo "=========================================="

section "比较函数 node_less"
warn "使用 container_of 从 bpf_rb_node 反推 struct node"
echo ""
llvm-objdump -d rbtree.bpf.o | grep -B2 -A5 'node_less' | head -15 || true
echo ""

section "bpf_rbtree_add 调用"
warn "R1=root, R2=node, R3=less函数指针, R4=NULL, R5=0"
echo ""
llvm-objdump -d rbtree.bpf.o | grep -E 'call' | head -10
echo ""

# Step 4: 加载测试
echo "=========================================="
echo "  Step 4: 加载测试 (需要 root)"
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

section "加载红黑树程序"
verify_log=$(mktemp)
bpftool prog load rbtree.bpf.o /sys/fs/bpf/rb_demo \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -E 'BTF loading|requires prog BTF|bpf_obj_new|processed' "$verify_log" || tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ (内核版本兼容)"
    sudo rm -f /sys/fs/bpf/rb_demo 2>/dev/null
else
    warn "加载失败 — BTF 兼容性问题 (kernel 6.19)"
    warn "与 03-list-operations 相同的 BTF 兼容性问题"
fi
sudo rm -f /sys/fs/bpf/rb_demo 2>/dev/null

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 查看 node_less 的字节码: container_of 如何实现"
warn "  2. 对比 bpf_rbtree_add 和 bpf_list_push_back 的 kfunc 签名差异"
warn "  3. 修改 node_less 返回值，观察编译器警告/错误"
warn "  4. 在支持的环境上: 添加 bpf_rbtree_first + bpf_obj_drop"
