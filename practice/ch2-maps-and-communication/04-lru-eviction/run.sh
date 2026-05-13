#!/usr/bin/env bash
# 04-lru-eviction: LRU Hash Map 自动淘汰演示
#
# 对应文档 Section 6.1 (LRU Hash Map)
#
# 本脚本:
# 1. 加载 LRU map 程序 (max_entries = 4)
# 2. 触发多次 fentry (cat /proc/loadavg 等)
# 3. 用 bpftool map dump 观察始终只有 4 条记录
# 4. 对比普通 HASH map 在同样场景下会报 -E2BIG

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

# Step 2: 加载
echo "=========================================="
echo "  Step 2: 加载 LRU 程序 (需要 root)"
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

sudo rm -f /sys/fs/bpf/lru_demo 2>/dev/null

section "加载 LRU Hash Map 程序"
warn "LRU map max_entries = 4 (最多存 4 条)"
echo ""
verify_log=$(mktemp)
bpftool prog load lru_demo.bpf.o /sys/fs/bpf/lru_demo \
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

# Step 3: 观察 LRU 淘汰行为
echo "=========================================="
echo "  Step 3: 观察 LRU 自动淘汰"
echo "=========================================="

section "初始状态 (map 应该为空)"
bpftool map dump name lru_map 2>/dev/null || echo "  (空)"
echo ""

warn "现在触发多次 fentry (每次 cat 会触发 do_sys_openat2)"
warn "不同进程的 pid 产生不同的 key，超过 4 个时 LRU 自动淘汰最老的"
echo ""

for i in $(seq 1 10); do
    cat /proc/loadavg > /dev/null 2>&1 || true
    ls /dev/null > /dev/null 2>&1 || true
    echo "." | tr -d '\n'
done
echo ""
echo ""

section "触发后的 Map 状态"
warn "观察: 始终只有 <= 4 条记录 (max_entries)"
echo ""
bpftool map dump name lru_map 2>/dev/null
entry_count=$(bpftool map dump name lru_map 2>/dev/null | grep -c 'key:' || echo "0")
echo ""
info "当前条目数: $entry_count / 4 (max_entries)"
if [[ "$entry_count" -le 4 ]]; then
    info "✓ LRU 淘汰正常: 条目数不超过 max_entries"
else
    warn "条目数超过 max_entries (意外)"
fi

echo ""

section "继续触发更多操作..."
for i in $(seq 1 20); do
    cat /proc/version > /dev/null 2>&1 || true
    date > /dev/null 2>&1 || true
    echo "." | tr -d '\n'
done
echo ""
echo ""

bpftool map dump name lru_map 2>/dev/null
entry_count=$(bpftool map dump name lru_map 2>/dev/null | grep -c 'key:' || echo "0")
echo ""
info "当前条目数: $entry_count / 4 (max_entries)"
echo ""

# 清理
sudo rm -f /sys/fs/bpf/lru_demo 2>/dev/null

echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. LRU_HASH 在 Map 满时自动淘汰最久未访问的条目"
warn "  2. 普通 HASH 满时插入返回 -E2BIG (需要手动处理)"
warn "  3. lookup 也会刷新访问时间 (防止活跃条目被淘汰)"
warn "  4. 适用于连接跟踪、会话缓存等无法预知 key 数量的场景"
warn "  5. 淘汰是静默的 — 不会通知 BPF 程序哪个条目被淘汰了"
