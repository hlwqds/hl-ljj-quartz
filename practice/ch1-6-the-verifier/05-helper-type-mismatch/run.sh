#!/usr/bin/env bash
# 05-helper-type-mismatch: Helper 参数类型不匹配
#
# 对应文档 Section 6.4
#
# 对比:
#   type_bad.bpf.o  → bpf_map_lookup_elem 传 scalar 而非 pointer
#   type_good.bpf.o → 正确传 pointer

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
make 2>&1
echo ""

# Step 2: 字节码对比
echo "=========================================="
echo "  Step 2: 字节码对比"
echo "=========================================="

section "bad: key 是 scalar (r2 = w1)"
warn "bpf_map_lookup_elem 期望 R2 是 pointer，但得到 scalar"
echo ""
llvm-objdump -d type_bad.bpf.o | grep -E 'r2|call|<type' | head -10
echo ""

section "good: &key 是 pointer (r2 = r10 - 4)"
warn "R2 = fp - 4 (栈指针)，是有效的 pointer 类型"
echo ""
llvm-objdump -d type_good.bpf.o | grep -E 'r2|call|<type' | head -10
echo ""

# Step 3: 加载测试
echo "=========================================="
echo "  Step 3: Verifier 加载测试 (需要 root)"
echo "=========================================="

if [[ $EUID -ne 0 ]]; then
    warn "非 root 用户，跳过"
    warn "运行 'sudo bash $0'"
    exit 0
fi

if ! command -v bpftool &>/dev/null; then
    warn "bpftool 未安装"
    exit 0
fi

# Case 1: bad
section "Case 1: type_bad (传 scalar)"
warn "预期: Verifier 报 'R2 type=scalar expected=ptr'"
echo ""
sudo rm -f /sys/fs/bpf/type_bad 2>/dev/null
verify_log=$(mktemp)
bpftool prog load type_bad.bpf.o /sys/fs/bpf/type_bad \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -iE 'R2|type|scalar|expected|ptr|invalid|arg' "$verify_log" || tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    warn "加载成功 (意外)"
    sudo rm -f /sys/fs/bpf/type_bad 2>/dev/null
else
    info "加载失败 ✓ — Helper 参数类型检查"
    warn "核心原因: bpf_map_lookup_elem(map, key) 签名要求第二个参数是指针"
    warn "          传了 key (u32 scalar) 而不是 &key (u32 *)"
    warn "          clang 不报错 (BPF helper 是运行时解析的)，Verifier 在加载时检查"
fi

# Case 2: good
unset ret || true
section "Case 2: type_good (传 pointer)"
warn "预期: 加载成功"
echo ""
sudo rm -f /sys/fs/bpf/type_good 2>/dev/null
verify_log=$(mktemp)
bpftool prog load type_good.bpf.o /sys/fs/bpf/type_good \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ — &key 是 PTR_TO_STACK，Verifier 确认类型匹配"
    sudo rm -f /sys/fs/bpf/type_good 2>/dev/null
else
    warn "加载失败 (意外)"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 尝试传 (void *)key 代替 key，观察 Verifier 是否接受 (int → ptr 的显式转换)"
warn "  2. 对比 kfunc: 传错参数给 kfunc 时 clang 编译就报错 (BTF 类型检查)"
warn "  3. 查看 bpf_helpers.h 中 bpf_map_lookup_elem 的声明方式"
