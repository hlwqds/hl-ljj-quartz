#!/usr/bin/env bash
# 03-list-operations: bpf_list_push_back 链表操作
#
# 对应文档 Section 5.1
#
# 演示: 分配节点 → push_back 到链表 → 所有权转移
#
# 注意: bpf_list_head 必须配合 btf_decl_tag("contains:<type>:<field>") 使用
#       缺少 decl_tag 会导致 BTF 加载 -EINVAL (kernel 6.2+)

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
echo "  Step 1: 编译链表程序"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null; make
echo ""

# Step 2: BTF 分析
echo "=========================================="
echo "  Step 2: BTF 类型分析"
echo "=========================================="

section "struct node 的 BTF 编码"
warn "bpf_list_node 是不透明类型 (opaque[3] = 3 个 u64)"
echo ""
bpftool btf dump file linked_list.bpf.o 2>/dev/null | grep -A5 "STRUCT 'node'\|STRUCT 'bpf_list_node'\|STRUCT 'bpf_list_head'"
echo ""

section "kfunc 在 BTF 中的声明"
warn "bpf_list_push_back_impl 是 extern __weak __ksym"
warn "参数: (bpf_list_head*, bpf_list_node*, void* meta__ign, u64 off)"
echo ""
bpftool btf dump file linked_list.bpf.o 2>/dev/null | grep -B2 -A5 "bpf_list_push_back_impl"
echo ""

# Step 3: 字节码分析
echo "=========================================="
echo "  Step 3: 字节码分析"
echo "=========================================="

section "bpf_obj_new 调用"
warn "bpf_core_type_id_local(struct node) → BTF type ID (编译时常量)"
echo ""
llvm-objdump -d linked_list.bpf.o | grep -E 'call|0x18' | head -10
echo ""

section "bpf_list_push_back 调用"
warn "参数通过 R1(head) R2(node) R3(NULL) R4(0) 传递"
echo ""
llvm-objdump -d linked_list.bpf.o | tail -10
echo ""

# Step 4: 尝试加载 (可能失败)
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

section "加载链表程序"
verify_log=$(mktemp)
bpftool prog load linked_list.bpf.o /sys/fs/bpf/list_demo \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -E 'BTF loading|requires prog BTF|bpf_obj_new|processed' "$verify_log" || tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ (内核版本兼容)"
    sudo rm -f /sys/fs/bpf/list_demo 2>/dev/null
else
    warn "加载失败 — 请检查 bpf_list_head 是否有 btf_decl_tag 注解"
    warn "运行 LIBBPF_LOG_LEVEL=debug 重新加载查看详细错误"
fi
sudo rm -f /sys/fs/bpf/list_demo 2>/dev/null

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 查看 bpftool btf dump file linked_list.bpf.o 了解 BTF 编码"
warn "  2. 对比 struct node (含 bpf_list_node) 和 struct my_data (简单结构) 的 BTF"
warn "  3. 在支持的环境上测试: 添加 bpf_list_pop_front + bpf_obj_drop"
warn "  4. 在 push_back 后尝试访问 n->value，观察编译器/Verifier 反应"
