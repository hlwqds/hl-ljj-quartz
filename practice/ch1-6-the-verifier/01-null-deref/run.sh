#!/usr/bin/env bash
# 01-null-deref: Verifier 最常见错误 — NULL 解引用
#
# 对应文档 Section 6.1
#
# 对比:
#   null_deref_bad.bpf.o  → map lookup 不判空，Verifier 拒绝
#   null_deref_good.bpf.o → 判空后访问，Verifier 通过

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
echo "  Step 1: 编译 (bad 和 good 都能编译通过)"
echo "=========================================="
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true
make 2>&1
echo ""

# Step 2: 字节码对比
echo "=========================================="
echo "  Step 2: 字节码对比"
echo "=========================================="

section "bad: 无判空，直接 *value += 1"
warn "map_lookup 返回后直接解引用，没有 if r0 == 0 的判空指令"
echo ""
llvm-objdump -d null_deref_bad.bpf.o | grep -E 'call|<null' | head -10
echo ""

section "good: 有判空，if r0 == 0 goto +1"
warn "map_lookup 后有 NULL 检查分支"
echo ""
llvm-objdump -d null_deref_good.bpf.o | grep -E 'call|if r0|<null' | head -10
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

# Case 1: bad — 预期 Verifier 拒绝
section "Case 1: null_deref_bad (不判空)"
warn "预期: Verifier 报 'R0 invalid mem access map_value_or_null'"
warn "注意: 使用 HASH map (ARRAY map 对已知 key 不会返回 NULL)"
echo ""
sudo rm -f /sys/fs/bpf/null_deref_bad 2>/dev/null
verify_log=$(mktemp)
bpftool prog load null_deref_bad.bpf.o /sys/fs/bpf/null_deref_bad \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -iE 'invalid|mem.access|read_ok|R0|scalar|NULL|null' "$verify_log" || tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    warn "加载成功 (意外: 应该被 Verifier 拒绝)"
    sudo rm -f /sys/fs/bpf/null_deref_bad 2>/dev/null
else
    info "加载失败 ✓ — Verifier 检测到 NULL 解引用风险"
    warn "核心原因: bpf_map_lookup_elem 返回 PTR_TO_MAP_VALUE_OR_NULL"
    warn "          不判空直接解引用 → Verifier 无法证明安全性"
fi

# Case 2: good — 预期加载成功
unset ret || true
section "Case 2: null_deref_good (正确判空)"
warn "预期: 加载成功"
echo ""
sudo rm -f /sys/fs/bpf/null_deref_good 2>/dev/null
verify_log=$(mktemp)
bpftool prog load null_deref_good.bpf.o /sys/fs/bpf/null_deref_good \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ — 判空后 Verifier 将类型从 OR_NULL 升级为有效指针"
    sudo rm -f /sys/fs/bpf/null_deref_good 2>/dev/null
else
    warn "加载失败 (意外)"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 在 good 版本中，把 if (!value) 改成 if (value == 0)，观察是否也能通过"
warn "  2. 尝试在判空后同时访问 value 和另一个 map lookup 的结果"
warn "  3. 用 bpftool prog dump xlated id <id> 查看加载后的寄存器状态"
