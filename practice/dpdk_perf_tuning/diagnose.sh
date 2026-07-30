#!/bin/bash
# diagnose.sh — DPDK 性能瓶颈定位脚本
#
# 用法:
#   ./diagnose.sh <dpdk_app_pid> <interface>
#
# 示例:
#   ./diagnose.sh $(pidof bad_l2fwd) eth0
#
# 输出每 2 秒刷新一次，按 Ctrl+C 停止

set -e

PID=${1:?"Usage: $0 <pid> <interface>"}
IFACE=${2:?"Usage: $0 <pid> <interface>"}
INTERVAL=2

echo "=== DPDK Performance Diagnosis ==="
echo "PID: $PID  IFACE: $IFACE  Interval: ${INTERVAL}s"
echo ""

# ──────────────────────────────────────────────
# 1. 系统基础
# ──────────────────────────────────────────────
echo "=== System Baseline ==="
echo "CPU isolcpus: $(cat /proc/cmdline | tr ' ' '\n' | grep isolcpus || echo 'not set')"
echo "Hugepages: $(grep HugePages_Total /proc/meminfo)"
echo "NIC NUMA node: $(cat /sys/class/net/$IFACE/device/numa_node 2>/dev/null || echo 'unknown')"
echo ""

# ──────────────────────────────────────────────
# 2. NUMA 检查
# ──────────────────────────────────────────────
echo "=== NUMA Alignment ==="
NIC_NUMA=$(cat /sys/class/net/$IFACE/device/numa_node 2>/dev/null || echo "-1")
PROC_NUMA=$(cat /proc/$PID/status 2>/dev/null | grep Cpus_allowed_list || echo "unknown")
echo "NIC on NUMA: $NIC_NUMA"
echo "Process CPU mask: $PROC_NUMA"

if [ "$NIC_NUMA" != "-1" ]; then
    echo ""
    echo "Checking if process threads are on same NUMA as NIC..."
    for tid in /proc/$PID/task/*; do
        tid_num=$(basename $tid)
        thread_numa=$(cat $tid/numa_maps 2>/dev/null | head -1 | grep -o 'N[0-9]*' | head -1 || echo "?")
        echo "  thread $tid_num: $thread_numa"
    done | head -10
fi
echo ""

# ──────────────────────────────────────────────
# 3. 循环诊断
# ──────────────────────────────────────────────
echo "=== Continuous Monitoring (Ctrl+C to stop) ==="
echo ""

PREV_RX_PACKETS=""
PREV_TX_PACKETS=""
PREV_RX_MISS=""
PREV_CYCLES=""

while true; do
    TIMESTAMP=$(date '+%H:%M:%S')

    # ── ethtool statistics ──
    RX_PACKETS=$(ethtool -S $IFACE 2>/dev/null | grep -i "rx_packets" | head -1 | awk '{print $2}')
    TX_PACKETS=$(ethtool -S $IFACE 2>/dev/null | grep -i "tx_packets" | head -1 | awk '{print $2}')
    RX_MISS=$(ethtool -S $IFACE 2>/dev/null | grep -iE "rx_missed|imissed|no_rx_desc" | head -1 | awk '{print $2}')
    RX_NOBUF=$(ethtool -S $IFACE 2>/dev/null | grep -iE "rx_alloc_failed|no_buffer" | head -1 | awk '{print $2}')

    # ── CPU usage ──
    CPU_LINE=$(cat /proc/$PID/stat 2>/dev/null | head -1)
    if [ -n "$CPU_LINE" ]; then
        UTIME=$(echo $CPU_LINE | awk '{print $14}')
        STIME=$(echo $CPU_LINE | awk '{print $15}')
        CYCLES=$((UTIME + STIME))
    else
        CYCLES=0
    fi

    # ── 计算增量 ──
    if [ -n "$PREV_CYCLES" ]; then
        DELTA_CYCLES=$((CYCLES - PREV_CYCLES))
        DELTA_RX=""
        DELTA_TX=""
        DELTA_MISS=""

        if [ -n "$RX_PACKETS" ] && [ -n "$PREV_RX_PACKETS" ]; then
            DELTA_RX=$((RX_PACKETS - PREV_RX_PACKETS))
            PPS_RX=$((DELTA_RX / INTERVAL))
        fi
        if [ -n "$TX_PACKETS" ] && [ -n "$PREV_TX_PACKETS" ]; then
            DELTA_TX=$((TX_PACKETS - PREV_TX_PACKETS))
            PPS_TX=$((DELTA_TX / INTERVAL))
        fi
        if [ -n "$RX_MISS" ] && [ -n "$PREV_RX_MISS" ]; then
            DELTA_MISS=$((RX_MISS - PREV_RX_MISS))
            MISS_RATE="0"
            if [ -n "$DELTA_RX" ] && [ "$DELTA_RX" -gt 0 ]; then
                MISS_RATE=$(echo "scale=4; $DELTA_MISS * 100 / $DELTA_RX" | bc 2>/dev/null || echo "?")
            fi
        fi

        echo "[$TIMESTAMP] CPU cycles: $DELTA_CYCLES | RX pps: ${PPS_RX:-?} | TX pps: ${PPS_TX:-?} | miss: ${DELTA_MISS:-?} (${MISS_RATE:-?}%)"
    fi

    PREV_RX_PACKETS=$RX_PACKETS
    PREV_TX_PACKETS=$TX_PACKETS
    PREV_RX_MISS=$RX_MISS
    PREV_CYCLES=$CYCLES

    sleep $INTERVAL
done
