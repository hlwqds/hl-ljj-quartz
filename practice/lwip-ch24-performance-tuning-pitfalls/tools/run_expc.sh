#!/usr/bin/env bash
# 实验 C：弱网(TX 丢帧) × 堆紧张 的 HTTP 服务行为画像（含恢复段）
set -u
cd "$(dirname "$0")/.."
LOG="logs/m_expc.log"; rm -f "$LOG" results/expc.log
for p in $(pgrep -f '^/home/huanglin/.espressif/tools/qemu-xtensa'); do
  tr '\0' ' ' < /proc/$p/cmdline | grep -q tcp::8028 && kill $p || true
done
sleep 1
( LOG="$LOG" tools/run_qemu.sh >/dev/null 2>&1 & )
for i in $(seq 1 30); do grep -q CTRLREADY "$LOG" 2>/dev/null && break; sleep 1; done
sleep 6
B="python3 tools/bench_host.py"
ctrl(){ $B ctrl --cmd "$1" >/dev/null; }
snap(){ { echo "--- $*"; ctrl "mem"; sleep 0.4; } >>results/expc.log; }
http(){ echo "### PHASE: $*" | tee -a results/expc.log; $B http --n ${N:-15} --timeout ${TMO:-5} 2>&1 | tee -a results/expc.log; }
{
echo "== ch24 expC $(date +%T) =="
echo "== p1 baseline =="; snap p1-before; N=12 TMO=5 http p1-baseline
echo "== p2 weak-uplink loss=15% =="; ctrl "loss 15"; sleep 1; N=12 TMO=5 http p2-loss15
echo "== p2b stop loss =="; ctrl "loss 0"; sleep 1; N=6 TMO=5 http p2-recover
echo "== p3 heap-stress -> free<=40KB =="; ctrl "heap 40"; sleep 1; N=8 TMO=5 http p3-heaptight
echo "== p3b release heap =="; ctrl "heap off"; sleep 1; N=5 TMO=5 http p3-recover
echo "== p4 combo loss15 + heap40 =="; ctrl "loss 15"; ctrl "heap 40"; sleep 1; N=15 TMO=6 http p4-combo
echo "== p5 full recovery =="; ctrl "loss 0"; ctrl "heap off"; sleep 2; N=10 TMO=5 http p5-recovered
} 2>&1 | tail -80
grep -cE '### DROP' "$LOG" | sed 's/^/dropped_frames_total_serial_lines=/' | tee -a results/expc.log
grep -E '\$\$\$ MEM' "$LOG" | tail -6 | sed 's/^/[fw] /' | tee -a results/expc.log
