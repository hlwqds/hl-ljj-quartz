#!/usr/bin/env bash
# 03-ringbuf-reserve: Ring Buffer Reserve-Submit 模式
#
# 对应文档 Section 5.4 (Ring Buffer 代码实战)
#
# 对比:
#   ringbuf_leak_bad.bpf.o  → reserve 不 submit → Verifier 报错 (内存泄漏)
#   ringbuf_good.bpf.o      → reserve → fill → submit → 加载成功

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
echo "  Step 2: Ring Buffer 字节码"
echo "=========================================="

section "bad: reserve 后不 submit"
warn "注意: 只有 bpf_ringbuf_reserve (call 130)，没有 bpf_ringbuf_submit"
echo ""
llvm-objdump -d ringbuf_leak_bad.bpf.o | grep -E 'call|r[0-9]' | head -15
echo ""

section "good: reserve → submit"
warn "完整的 Reserve-Submit 三步曲"
echo ""
llvm-objdump -d ringbuf_good.bpf.o | grep -E 'call|r[0-9]' | head -15
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
section "Case 1: ringbuf_leak_bad (reserve 不 submit)"
warn "预期: Verifier 报 'Unreleased ringbuf memory' 或 'leaked'"
echo ""
sudo rm -f /sys/fs/bpf/ringbuf_bad 2>/dev/null
verify_log=$(mktemp)
bpftool prog load ringbuf_leak_bad.bpf.o /sys/fs/bpf/ringbuf_bad \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
grep -iE 'ringbuf|leak|unreleased|memory|R[0-9]' "$verify_log" | head -5 || tail -5 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    warn "加载成功 (意外)"
    sudo rm -f /sys/fs/bpf/ringbuf_bad 2>/dev/null
else
    info "加载失败 ✓ — Ring Buffer 预留内存未释放"
    warn "  Verifier 追踪 ringbuf 指针: reserve 后必须 submit 或 discard"
    warn "  否则预留的 ringbuf 空间永远不会回收 → 内存泄漏"
fi

# Case 2: good
unset ret || true
section "Case 2: ringbuf_good (reserve → submit)"
warn "预期: 加载成功"
echo ""
sudo rm -f /sys/fs/bpf/ringbuf_good 2>/dev/null
verify_log=$(mktemp)
bpftool prog load ringbuf_good.bpf.o /sys/fs/bpf/ringbuf_good \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""
if [[ $ret -eq 0 ]]; then
    info "加载成功 ✓ — Reserve-Submit 模式正确"
    sudo rm -f /sys/fs/bpf/ringbuf_good 2>/dev/null
else
    warn "加载失败 (意外)"
fi

echo ""
echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. Ring Buffer 写入三步: reserve → fill → submit"
warn "  2. reserve 返回的指针必须在 submit 或 discard 前有效"
warn "  3. Verifier 追踪 ringbuf 指针，忘记 submit 会报错"
warn "  4. bpf_ringbuf_discard() 可以取消已 reserve 的空间"
warn "  5. 2026 年推荐 Ring Buffer 代替 Perf Event Array"
