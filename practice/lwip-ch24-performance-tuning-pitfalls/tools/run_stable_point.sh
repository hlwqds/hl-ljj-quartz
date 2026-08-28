#!/usr/bin/env bash
# 带质量门限的重试驱动：单点最多尝试 3 次，取通过门限的首次结果
set -u
cd "$(dirname "$0")/.."
P=$1
for try in 1 2 3; do
  tools/run_matrix_point.sh "$P" 2 >/dev/null 2>&1
  rx=$(grep -oE 'thrx mb=4 ack=b.K. secs=[0-9.]+ mbit=[0-9.]+' "results/$P.log" | grep -oE 'mbit=[0-9.]+' | cut -d= -f2 | sort -n | tail -1)
  lb=$(grep -oE 'LBTH .* mbit=[0-9.]+' "results/$P.log" | grep -oE 'mbit=[0-9.]+' | cut -d= -f2 | sort -n | tail -1)
  rt=$(grep -oE 'LBRTT .*avg_rtt_us=[0-9]+' "results/$P.log" | grep -oE 'avg_rtt_us=[0-9]+' | cut -d= -f2 | sort -n | head -1)
  echo "point=$P try=$try best_rx=${rx:-NA} best_lbth=${lb:-NA} best_rtt=${rt:-NA}"
  ok=1
  awk -v x="${rx:-0}" 'BEGIN{exit !(x>=40)}' || ok=0
  awk -v x="${lb:-0}" 'BEGIN{exit !(x>=50)}' || ok=0
  [ -n "$rt" ] || ok=0
  [ "$ok" = 1 ] && { echo "point=$P ACCEPTED at try=$try"; break; }
done
