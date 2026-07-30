#!/bin/bash
# compare_tools.sh — 同一故障, 4 个工具分别能看到什么
#
# 用法:
#   ./compare_tools.sh <dpdk_app_pid> <nic_name>
#
# 示例:
#   ./compare_tools.sh $(pidof fault_inject_app) eth0
#
# 演示 4 类工具在 DPDK 拥有网卡后的"失明"程度:
#   1. ethtool -S       物理层错误计数
#   2. ss -s            协议栈统计
#   3. ip -s link       设备层统计
#   4. dpdk-procinfo    DPDK 内部状态

set -e

PID=${1:?"Usage: $0 <dpdk_app_pid> <nic_name>"}
IFACE=${2:?"Usage: $0 <dpdk_app_pid> <nic_name>"}

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查进程存在
if ! kill -0 $PID 2>/dev/null; then
    echo "Error: PID $PID not found"
    exit 1
fi

# 探测网卡是否被 DPDK 拥有
DPDK_OWNS_NIC=false
if ls /sys/class/net/$IFACE/device/driver 2>/dev/null | grep -qE "(vfio-pci|igb_uio|uio_pci_generic)"; then
    DPDK_OWNS_NIC=true
fi

echo "=========================================================="
echo "  DPDK 工具能力对比演示"
echo "=========================================================="
echo "PID:      $PID"
echo "网卡:     $IFACE"
echo "DPDK 拥有: $DPDK_OWNS_NIC"
echo ""

# ──────────────────────────────────────────────
# Section 1: 工具 1 — ethtool
# ──────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "工具 1: ethtool -S $IFACE (网卡硬件计数器)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$DPDK_OWNS_NIC" = true ]; then
    echo -e "${RED}ethtool 失明: 网卡被 DPDK 拥有, ethtool 拿不到数据${NC}"
    echo "执行: ethtool -S $IFACE"
    ethtool -S $IFACE 2>&1 | head -5 || echo "  → (设备不存在, 驱动未暴露 sysfs)"
else
    echo -e "${GREEN}ethtool 正常返回 (网卡归内核驱动)${NC}"
    ethtool -S $IFACE 2>/dev/null | grep -E "rx_packets|tx_packets|rx_dropped|rx_errors|rx_missed" | head -10
fi
echo ""

# ──────────────────────────────────────────────
# Section 2: 工具 2 — ss
# ──────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "工具 2: ss -s (内核协议栈统计)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "执行: ss -s"
ss -s
echo ""
echo "解读: ss 只看内核 TCP/UDP 协议栈"
echo "      - DPDK 应用的连接 (L4 代理 / 网关) 完全不在这里"
echo "      - 即使网卡流量打满, TCP established 也不变"
echo ""

# ──────────────────────────────────────────────
# Section 3: 工具 3 — ip -s link
# ──────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "工具 3: ip -s link show $IFACE (设备层统计)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$DPDK_OWNS_NIC" = true ]; then
    echo -e "${RED}ip link 失明: 网卡被 DPDK 接管, 内核统计停更${NC}"
    echo "执行: ip -s link show $IFACE"
    ip -s link show $IFACE 2>&1 | head -5
    echo ""
    echo "  → 注意: RX/TX packets 数字可能停在上次 bind 前的值"
else
    echo -e "${GREEN}ip link 正常 (网卡归内核)${NC}"
    ip -s link show $IFACE | grep -A 1 "RX\|TX"
fi
echo ""

# ──────────────────────────────────────────────
# Section 4: 工具 4 — dpdk-procinfo
# ──────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "工具 4: dpdk-procinfo (DPDK 内部状态)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
DPDK_PROCINFO=""
for path in \
    /opt/dpdk/build/app/dpdk-procinfo \
    ./build/app/dpdk-procinfo \
    $(dirname $(readlink -f $0))/../dpdk_perf_tuning/../../build/app/dpdk-proc-info; do
    if [ -x "$path" ]; then
        DPDK_PROCINFO="$path"
        break
    fi
done

if [ -z "$DPDK_PROCINFO" ]; then
    echo -e "${YELLOW}dpdk-procinfo 未找到, 跳过 (需要 DPDK 24.x)${NC}"
    echo "  提示: 从 /opt/dpdk 编译, 或用 usertools/dpdk-procinfo.py"
    echo ""
    echo "如果应用是 dpdk-l2fwd 风格, 关键字段预期能看到:"
    echo "  Port 0 RX: Packets=N Errors=0 Nombufs=0"
    echo "  Port 1 RX: Packets=N Errors=0 Nombufs=N   ← mbuf 泄漏"
    echo "  Port 2 TX: Used=1024/1024                  ← 队列满"
    echo "  Mbuf Pool: Used=8000/8191 (97%)            ← 接近耗尽"
else
    echo "执行: $DPDK_PROCINFO -- --proc-type=auto"
    $DPDK_PROCINFO -- --proc-type=auto --file-prefix=$(grep file_prefix /proc/$PID/cmdline 2>/dev/null | tr '\0' ' ' || echo unknown) 2>&1 | head -40
fi
echo ""

# ──────────────────────────────────────────────
# Section 5: 总结
# ──────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  对比总结"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-25s | %-15s | %-30s\n" "工具" "DPDK 拥有时" "能看到的字段"
echo "--------------------------+-----------------+--------------------------------"
printf "%-25s | %-15s | %-30s\n" "ethtool -S"        "$([ "$DPDK_OWNS_NIC" = true ] && echo 失明 || echo 正常)" "rx_packets, rx_errors, ..."
printf "%-25s | %-15s | %-30s\n" "ss -s"             "失明 (协议栈无关)" "TCP established, ..."
printf "%-25s | %-15s | %-30s\n" "ip -s link"        "$([ "$DPDK_OWNS_NIC" = true ] && echo 失明 || echo 正常)" "RX/TX bytes, errors, ..."
printf "%-25s | %-15s | %-30s\n" "dpdk-procinfo"     "✓ 唯一能看到" "port/queue/mbuf/lcore 状态"
echo ""
echo "结论: DPDK 跑起来后, 只有 dpdk-procinfo / 应用 CLI / Telemetry 能看"
