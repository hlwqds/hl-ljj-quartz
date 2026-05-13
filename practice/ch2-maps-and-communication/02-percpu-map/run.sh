#!/usr/bin/env bash
# 02-percpu-map: Per-CPU Map 计数器
#
# 对应文档 Section 4.2 (Per-CPU Map：无锁并发的秘密)
#
# 本脚本:
# 1. 编译 Per-CPU 计数器程序
# 2. 加载到 XDP
# 3. 用 bpftool map dump 展示每个 CPU 的独立计数
# 4. 对比 Per-CPU vs 普通 ARRAY 的字节码差异

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
echo "  Step 2: 字节码 — Per-CPU vs 普通 ARRAY"
echo "=========================================="

section "Per-CPU: 直接 += 1 (无锁)"
warn "bpf_map_lookup_elem 返回当前 CPU 的副本指针"
warn "直接写入，不需要 __sync_fetch_and_add"
echo ""
llvm-objdump -d percpu_counter.bpf.o | grep -A2 'call 1' | head -6
echo ""

section "普通 ARRAY: __sync_fetch_and_add (原子操作)"
warn "需要原子操作保证跨 CPU 正确性"
warn "每次 += 1 产生 lock prefix，有 cache line bouncing 开销"
echo ""
llvm-objdump -d percpu_counter.bpf.o | grep -A2 'lock' | head -6
echo ""

# Step 3: 加载 & 观察
echo "=========================================="
echo "  Step 3: 加载并观察 Per-CPU Map (需要 root)"
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

sudo rm -f /sys/fs/bpf/percpu_counter 2>/dev/null

section "加载 Per-CPU 计数器"
verify_log=$(mktemp)
bpftool prog load percpu_counter.bpf.o /sys/fs/bpf/percpu_counter type xdp \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""

if [[ $ret -ne 0 ]]; then
    warn "加载失败，跳过后续步骤"
    exit 0
fi

info "加载成功 ✓"

# 获取 map id
map_id=$(bpftool map show pinned /sys/fs/bpf/percpu_counter 2>/dev/null \
    | grep -oP 'id \K\d+' | head -1 || echo "")

if [[ -z "$map_id" ]]; then
    # 尝试通过 prog 获取 map
    warn "无法获取 map id，尝试直接 dump"
    section "Per-CPU Map (proto_counter)"
    bpftool map dump name proto_counter 2>/dev/null || warn "无法 dump map"
    echo ""
else
    # 找到 percpu map
    percpu_map_id=$(bpftool map show id $map_id 2>/dev/null | head -1 | grep -oP 'id \K\d+' || echo "")
    section "Per-CPU Map (proto_counter)"
    warn "每个 CPU 有独立的 value 副本"
    echo ""
    bpftool map dump name proto_counter 2>/dev/null || true
    echo ""

    section "普通 ARRAY Map (proto_counter_locked)"
    warn "所有 CPU 共享同一个 value"
    echo ""
    bpftool map dump name proto_counter_locked 2>/dev/null || true
    echo ""
fi

warn "观察要点:"
warn "  1. Per-CPU map: 每个 CPU 有独立的 value (percpu: yes)"
warn "  2. 普通 ARRAY: 所有 CPU 共享同一个 value"
warn "  3. Per-CPU 无需锁 → XDP 场景下吞吐量翻倍 (文档 Section 4.2)"
echo ""

# 清理
sudo rm -f /sys/fs/bpf/percpu_counter 2>/dev/null

echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. Per-CPU Map 为每个 CPU 分配独立副本"
warn "  2. 直接写入，无需 __sync_fetch_and_add 或 spin_lock"
warn "  3. XDP 场景: Per-CPU ~30 Mpps vs 普通 +atomic ~15 Mpps"
warn "  4. 用户态读取需遍历所有 CPU 并聚合结果"
warn "  5. 容器环境中 CPU 数不同可能导致 Map 大小不匹配"
