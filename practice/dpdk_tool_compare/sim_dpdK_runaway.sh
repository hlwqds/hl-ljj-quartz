#!/bin/bash
# sim_dpdk_runaway.sh — 模拟"网卡被 DPDK 拥有后, 内核工具失明"的演示
#
# 不用真实 DPDK 硬件, 用一个长跑进程 + 高 CPU 占用, 模拟 DPDK 行为
# 然后跑 4 个工具对比看效果.
#
# 这个脚本是教学性质的: 让没 DPDK 环境的人也能理解"工具能力边界"

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SIM_BIN=""
for try in /tmp/dpdk_sim_$$ /tmp/dpdk_sim; do
    cat > $try.c <<'EOF'
#include <stdio.h>
#include <signal>
#include <unistd.h>
volatile int run = 1;
void h(int s) { run = 0; }
int main(int argc, char **argv) {
    signal(SIGINT, h); signal(SIGTERM, h);
    long i = 0;
    while (run) {
        /* busy loop, 模拟 DPDK polling */
        for (volatile long j = 0; j < 1000000; j++);
        if (++i % 100000 == 0)
            fprintf(stderr, "[sim] tick %ld\n", i);
    }
    return 0;
}
EOF
    if gcc -O2 -o $try $try.c 2>/dev/null; then
        SIM_BIN=$try
        break
    fi
done
if [ -z "$SIM_BIN" ]; then
    echo "Error: cannot compile sim binary"
    exit 1
fi

cleanup() {
    if [ -n "$SIM_PID" ] && kill -0 $SIM_PID 2>/dev/null; then
        kill $SIM_PID 2>/dev/null || true
        wait $SIM_PID 2>/dev/null || true
    fi
    rm -f $SIM_BIN $SIM_BIN.c
}
trap cleanup EXIT

echo "=========================================================="
echo "  DPDK 工具能力边界演示 (无 DPDK 硬件也能跑)"
echo "=========================================================="
echo ""
echo "背景: DPDK 跑起来后, 它独占了网卡. ethtool / ss / ip"
echo "      等内核工具拿不到真实数据. 下面用 4 个工具分别"
echo "      '模拟探测' 这个进程 + 网卡, 看各自能拿到什么."
echo ""

# 启动模拟进程
$SIM_BIN &
SIM_PID=$!
echo -e "${CYAN}启动模拟 DPDK 进程, PID=$SIM_PID${NC}"
sleep 1

IFACE="eth0"
[ -d /sys/class/net/$IFACE ] || IFACE="lo"

echo ""
echo "──────────────────────────────────────────────────────────"
echo "工具 1: ethtool -S $IFACE"
echo "──────────────────────────────────────────────────────────"
echo "目标: 看网卡硬件计数 (rx_packets, tx_packets, rx_errors)"
ETHOUT=$(ethtool -S $IFACE 2>&1)
if echo "$ETHOUT" | grep -q "no stats available\|Operation not supported\|not supported"; then
    echo -e "${YELLOW}ethtool 失明: 网卡归 DPDK 之后, 驱动 sysfs 切走${NC}"
    echo "  报错: $(echo "$ETHOUT" | head -1)"
    echo ""
    echo "  等效 DPDK 行为:"
    echo "    $ ethtool -S eth0"
    echo "    Cannot get driver information: No such device"
else
    echo -e "${GREEN}ethtool 正常 (网卡归内核, 模拟环境)${NC}"
    echo "$ETHOUT" | grep -E "rx_packets|tx_packets|rx_errors" | head -5
fi
echo ""

echo "──────────────────────────────────────────────────────────"
echo "工具 2: ss -s"
echo "──────────────────────────────────────────────────────────"
echo "目标: 看 TCP/UDP 连接数"
ss -s
echo ""
echo "  解读: ss 只看内核协议栈"
echo "        - 上面那个 PID=$SIM_PID 是个不联网的 busy loop"
echo "        - 所以 ss 输出完全不体现它的存在"
echo "        - 真 DPDK 场景: L4 proxy / gateway 的连接都看不到"
echo ""

echo "──────────────────────────────────────────────────────────"
echo "工具 3: ip -s link show $IFACE"
echo "──────────────────────────────────────────────────────────"
echo "目标: 看设备层 RX/TX bytes/packets"
ip -s link show $IFACE 2>/dev/null | head -10
echo ""
echo "  解读: ip link 走内核驱动层的 netdev stats"
echo "        DPDK 拥有网卡后, 这数据停更 (停在 bind 前的值)"
echo ""

echo "──────────────────────────────────────────────────────────"
echo "工具 4: 'dpdk-procinfo' (这里用 ps/lsof 模拟)"
echo "──────────────────────────────────────────────────────────"
echo "目标: 看 DPDK 进程内部状态 (mempool, queue, lcore)"
ps -p $SIM_PID -o pid,pcpu,pmem,vsz,rss,etime,comm 2>/dev/null
echo ""
echo "CPU 占用: $(ps -p $SIM_PID -o pcpu= 2>/dev/null || echo "?")% (模拟 lcore 100% 占用)"
echo ""
echo "  等效真实 DPDK 下 dpdk-procinfo 的输出:"
cat <<'EOF'
  Port 0: 0000:3d:00.0
    Driver: net_i40e
    RX: Packets: 12345678  Nombufs: 0      ← 真实包数, 内核工具看不到
    TX: Packets: 12345600
  Queue 0 RX: Used: 256/1024
  Queue 0 TX: Used:    0/1024
  LCore 0: State: RUNNING  CPU: 3
  Mbuf Pool: Used: 256/8191  Cache: 32/256
EOF
echo ""

echo "──────────────────────────────────────────────────────────"
echo "对比总结"
echo "──────────────────────────────────────────────────────────"
printf "%-25s | %-20s | %-30s\n" "工具" "看 DPDK 内部?" "实际能看到"
echo "--------------------------+----------------------+--------------------------------"
printf "%-25s | %-20s | %-30s\n" "ethtool -S"        "✗ (网卡归 DPDK)"  "完全看不到"
printf "%-25s | %-20s | %-30s\n" "ss -s"             "✗ (协议栈无关)"  "只能看进程无关的 TCP"
printf "%-25s | %-20s | %-30s\n" "ip -s link"        "✗ (驱动 sysfs 切走)" "数字停更"
printf "%-25s | %-20s | %-30s\n" "dpdk-procinfo"     "✓"                "mempool/queue/lcore 全看到"
echo ""
echo "结论: DPDK 跑起来后只有 dpdk-procinfo / 应用 CLI / Telemetry 能看"

kill $SIM_PID 2>/dev/null || true
wait $SIM_PID 2>/dev/null || true
