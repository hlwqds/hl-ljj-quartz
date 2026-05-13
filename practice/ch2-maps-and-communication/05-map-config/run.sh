#!/usr/bin/env bash
# 05-map-config: Map 作为配置下发通道
#
# 对应文档 Section 7 (内核态-用户态通信模式)
#
# 本脚本展示 Map 最核心的价值之一:
#   用户态写配置 → BPF 程序实时读取 → 无需重载程序
#
# 流程:
#   1. 加载 BPF 程序 (从 config_map 读取默认配置)
#   2. 用 bpftool map update 修改配置 (允许特定 PID)
#   3. 触发 syscalls，观察统计 Map 变化

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
echo "  Step 2: 加载 (需要 root)"
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

sudo rm -f /sys/fs/bpf/map_config 2>/dev/null
verify_log=$(mktemp)
bpftool prog load map_config.bpf.o /sys/fs/bpf/map_config \
    > "$verify_log" 2>&1 || ret=$?
ret=${ret:-0}
tail -3 "$verify_log"
rm -f "$verify_log"
echo ""

if [[ $ret -ne 0 ]]; then
    warn "加载失败，跳过"
    exit 0
fi

info "加载成功 ✓"

# Step 3: 查看默认配置
section "默认配置 (config_map)"
warn "allowed_pid=0 → 跟踪所有进程的 open 调用"
echo ""
bpftool map dump name config_map 2>/dev/null
echo ""

# Step 4: 修改配置 — 只跟踪当前 shell 的 PID
MY_PID=$$
section "修改配置: 只跟踪 PID $MY_PID"
warn "用户态通过 bpftool map update 修改 BPF Map"
warn "BPF 程序下次读取时自动看到新值 — 无需重载!"
echo ""

# 更新 allowed_pid
printf '%s' "$MY_PID" | bpftool map update name config_map key 0 2>/dev/null
warn "config_map[0].allowed_pid = $MY_PID"
echo ""

# 更新 timestamp
bpftool map update name config_map key 0 value \
    "{ \"allowed_pid\": $MY_PID, \"min_bytes\": 0, \"timestamp\": $(date +%s) }" 2>/dev/null \
    || warn "bpftool JSON update 可能不支持，用 hex 方式"

section "更新后的配置"
bpftool map dump name config_map 2>/dev/null
echo ""

# Step 5: 触发 syscalls 并观察
section "触发 open 调用"
warn "执行 cat /proc/loadavg 等命令触发 sys_enter_openat"
warn "BPF 程序从 config_map 读取 allowed_pid=$MY_PID"
warn "只有 PID=$MY_PID 的 open 才会计入 stats_map"
echo ""

# 清空统计
bpftool map delete name stats_map 2>/dev/null || true

for i in $(seq 1 5); do
    cat /proc/loadavg > /dev/null 2>&1 || true
    ls /dev/null > /dev/null 2>&1 || true
done
echo "  (5 次 open 完成)"
echo ""

section "统计结果 (stats_map)"
warn "只有 PID=$MY_PID 被统计 (其他 PID 的 open 被 config 过滤)"
echo ""
bpftool map dump name stats_map 2>/dev/null || echo "  (空)"
echo ""

# Step 6: 改回全局跟踪
section "恢复全局跟踪: allowed_pid=0"
printf '%s' "0" | bpftool map update name config_map key 0 2>/dev/null
warn "现在所有进程的 open 都会被统计"
echo ""

bpftool map delete name stats_map 2>/dev/null || true
for i in $(seq 1 5); do
    cat /proc/version > /dev/null 2>&1 || true
    date > /dev/null 2>&1 || true
done
echo "  (5 次 open 完成)"
echo ""

section "全局统计结果"
bpftool map dump name stats_map 2>/dev/null || echo "  (空)"
echo ""

# 清理
sudo rm -f /sys/fs/bpf/map_config 2>/dev/null

echo "=========================================="
echo "  完成!"
echo "=========================================="
warn "核心教训:"
warn "  1. Map 是用户态→内核态的配置下发通道"
warn "  2. bpftool map update 修改配置 → BPF 程序实时生效"
warn "  3. 无需重载 BPF 程序就能改变行为 — 这是 Map 的核心价值"
warn "  4. 生产环境: Cilium/Falco/Pixie 都用这个模式做动态配置"
warn "  5. 对比: Ring Buffer 是内核态→用户态的事件上报通道 (反向)"
