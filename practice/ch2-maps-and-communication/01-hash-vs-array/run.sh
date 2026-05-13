#!/usr/bin/env bash
# 01-hash-vs-array: HASH Map vs ARRAY Map 返回类型
#
# 对应文档 Section 3 (Hash Map) + Section 4.1 (Array Map)
#
# 核心区别:
#   HASH  → bpf_map_lookup_elem 返回 PTR_TO_MAP_VALUE_OR_NULL → 必须判空
#   ARRAY → bpf_map_lookup_elem 返回 PTR_TO_MAP_VALUE → 无需判空

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
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

section "bad: HASH map lookup (返回 OR_NULL)"
warn "注意 call bpf_map_lookup_elem 后的指令"
warn "Verifier 看到返回值是 PTR_TO_MAP_VALUE_OR_NULL"
echo ""
llvm-objdump -d hash_null_bad.bpf.o | head -20
echo ""

section "good: ARRAY map lookup (返回非 NULL)"
warn "同样的代码，但 Verifier 知道 ARRAY 对有效 key 永远返回有效指针"
echo ""
llvm-objdump -d array_no_null_good.bpf.o | head -20
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
    warn "bpftool 未安装，跳过"
    exit 0
fi

# Case 1: bad
unset ret || true
section "Case 1: hash_null_bad (HASH 不判空)"
warn "预期: Verifier 报 'invalid mem access .* map_value_or_null'"
echo ""
sudo rm -f /sys/fs/bpf/hash_null_bad 2>/dev/null
verify_log=$(mktemp)
bpftool prog load hash_null_bad.bpf.o /sys/fs/bpf/hash_null_bad \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -iE 'invalid|or_null|scalar|mem.access|R[0-9]' "$verify_log" | head -5 || tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    warn "加载成功 (意外)"
    sudo rm -f /sys/fs/bpf/hash_null_bad 2>/dev/null
else
    info "加载失败 ✓ — HASH 返回 PTR_TO_MAP_VALUE_OR_NULL，必须判空"
fi

# Case 2: good
unset ret || true
section "Case 2: array_no_null_good (ARRAY 无需判空)"
warn "预期: 加载成功"
echo ""
sudo rm -f /sys/fs/bpf/array_no_null_good 2>/dev/null
verify_log=$(mktemp)
bpftool prog load array_no_null_good.bpf.o /sys/fs/bpf/array_no_null_good \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ — ARRAY 对有效 key 返回 PTR_TO_MAP_VALUE，无需判空"
    sudo rm -f /sys/fs/bpf/array_no_null_good 2>/dev/null
else
    warn "加载失败 (意外)"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. HASH map: lookup 可能返回 NULL → 必须判空"
warn "  2. ARRAY map: lookup 对有效 key 永远非 NULL → 无需判空"
warn "  3. Verifier 追踪精确类型: OR_NULL vs 非 NULL"
warn "  4. ARRAY 更快 (O(1) 直接寻址)，但不支持删除"
warn "  5. HASH 更灵活 (任意 key)，但需要 NULL 检查 + 可能的锁竞争"
