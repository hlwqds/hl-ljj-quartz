#!/usr/bin/env bash
# 杀旧实例->启动->等就绪->固定负载测量：thrx xN + rtt + th + mem/TX 方向(可选)
set -u
cd "$(dirname "$0")/.."
LABEL=${1:?label}
ROUNDS=${2:-2}
LOG="logs/m_$LABEL.log"; rm -f "$LOG" "results/$LABEL.log"
for p in $(pgrep -f '^/home/huanglin/.espressif/tools/qemu-xtensa'); do
  tr '\0' ' ' < /proc/$p/cmdline | grep -q tcp::8028 && kill $p || true
done
sleep 1
( LOG="$LOG" tools/run_qemu.sh >/dev/null 2>&1 & )
for i in $(seq 1 30); do grep -q CTRLREADY "$LOG" 2>/dev/null && break; sleep 1; done
sleep 5                                     # DHCP/ARP 稳定
B="python3 tools/bench_host.py"
ctrl(){ $B ctrl --cmd "$1" >/dev/null; }
harvest(){ grep -E '\$\$\$ (LBRTT|LBTH |MEM on)' "$LOG" | tail -n "${1:-4}" | sed 's/^/[fw] /' >>"results/$LABEL.log"; }
{
echo "== point $LABEL rounds=$ROUNDS $(date +%T) =="
for ((r=1;r<=ROUNDS;r++)); do
  echo "--- round $r ---"
  $B --mb 4 --timeout 8 thrx
  ctrl "rtt 200 512"; sleep 3
  ctrl "th 4000000";  sleep 7
done
ctrl "mem"; sleep 0.5
} | tee -a "results/$LABEL.log"
harvest $((6*ROUNDS))
tail -1 "$LOG" | grep HEART >>"results/$LABEL.log" || true
grep BUILD "$LOG" >>"results/$LABEL.log"
