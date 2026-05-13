#!/usr/bin/env bash
# 03-state-merge: 寄存器状态合并退化
#
# 对应文档 Section 2.2
#
# 对比:
#   merge_bad.bpf.o  → if/else 赋不同类型，合并退化为 scalar
#   merge_good.bpf.o → 两分支赋相同类型，合并后正常判空

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

# Step 2: Verifier 测试
echo "=========================================="
echo "  Step 2: Verifier 加载测试 (需要 root)"
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

# Case 1: bad — 状态退化
section "Case 1: merge_bad (不同类型指针合并)"
warn "路径 A: p = map_value_or_null (指针)"
warn "路径 B: p = 0 (标量)"
warn "合并后: SCALAR_VALUE (退化为标量，不能解引用)"
echo ""
sudo rm -f /sys/fs/bpf/merge_bad 2>/dev/null
verify_log=$(mktemp)
bpftool prog load merge_bad.bpf.o /sys/fs/bpf/merge_bad \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -iE 'scalar|invalid|mem.access|type' "$verify_log" || tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    warn "加载成功 (意外: 应该被 Verifier 拒绝)"
    sudo rm -f /sys/fs/bpf/merge_bad 2>/dev/null
else
    info "加载失败 ✓ — Verifier 状态合并将指针退化为标量"
    warn "核心原理:"
    warn "  路径 A 的 PTR_TO_MAP_VALUE_OR_NULL + 路径 B 的 SCALAR_VALUE"
    warn "  → 合并为 SCALAR_VALUE (最保守)"
    warn "  → 不能对 scalar 做指针解引用"
fi

# Case 2: good
unset ret || true
section "Case 2: merge_good (两分支同类型)"
warn "两分支都赋 PTR_TO_MAP_VALUE_OR_NULL"
warn "合并后: PTR_TO_MAP_VALUE_OR_NULL (类型不退化)"
echo ""
sudo rm -f /sys/fs/bpf/merge_good 2>/dev/null
verify_log=$(mktemp)
bpftool prog load merge_good.bpf.o /sys/fs/bpf/merge_good \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ — 同类型合并不退化，判空后正常使用"

    section "Verifier 状态合并速查表 (来自文档 Section 2.2)"
    warn "  PTR_TO_MAP_VALUE   + PTR_TO_MAP_VALUE   = PTR_TO_MAP_VALUE   (不退化)"
    warn "  PTR_TO_MAP_VALUE   + SCALAR_VALUE        = SCALAR_VALUE        (退化!)"
    warn "  PTR_OR_NULL        + PTR_TO_MAP_VALUE    = PTR_OR_NULL        (保守)"
    warn "  NOT_INIT           + SCALAR_VALUE        = NOT_INIT           (不安全)"

    sudo rm -f /sys/fs/bpf/merge_good 2>/dev/null
else
    warn "加载失败 (意外)"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "练习建议:"
warn "  1. 在 bad 版本中，把 else 分支也改成 map_lookup，观察是否能通过"
warn "  2. 把 else 改成 p = NULL (显式 NULL 常量)，观察是否也是 scalar"
warn "  3. 添加第三条路径 (else if)，观察三方合并的结果"
