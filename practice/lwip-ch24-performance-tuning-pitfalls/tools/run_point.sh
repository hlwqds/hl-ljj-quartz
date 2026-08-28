#!/usr/bin/env bash
# ch24 单测量点驱动：对当前运行的 QEMU 实例执行固定负载序列并把结果落盘。
# 用法: [LOG=logs/xxx.log] run_point.sh <label> [rounds]
# 依赖: tools/bench_host.py（端口默认 8028/8029/8030）
set -u
cd "$(dirname "$0")/.."
LABEL=${1:?label}
ROUNDS=${2:-3}
LOG=${LOG:-run.log}
OUT="results"
mkdir -p "$OUT"

B="python3 tools/bench_host.py"
ctrl() { $B ctrl --cmd "$1" >/dev/null; }
harvest() { grep -E '\$\$\$ (LBRTT|LBTH|MEM|RXDONE|TXPUMP|DROP)' "$LOG" | tail -n "${1:-6}" \
            | sed 's/^/[fw] /' ; }

echo "== point $LABEL rounds=$ROUNDS $(date +%T) ==" | tee -a "$OUT/$LABEL.log"

for ((r=1; r<=ROUNDS; r++)); do
    echo "--- round $r $(date +%T) ---" | tee -a "$OUT/$LABEL.log"
    ctrl "mem"; sleep 0.5
    echo "[fw] mem snapshot below" >>"$OUT/$LABEL.log"; harvest 1 >>"$OUT/$LABEL.log"
    # 口径1a: SLIRP 外环 host->guest 4MB
    $B --mb 4 thrx |tee -a "$OUT/$LABEL.log"
    # 口径1b: SLIRP 外环 guest->host 4MB（先切 pump 模式）
    ctrl "sinkmode tx"; sleep 0.3
    $B --mb 4 thtx |tee -a "$OUT/$LABEL.log"
    ctrl "sinkmode rx"; sleep 0.3
    # 口径2a: guest 内 loopback 批量 4MB
    ctrl "th 4000000"; sleep 6
    echo "[fw] lb-th:" >>"$OUT/$LABEL.log"; harvest 2 >>"$OUT/$LABEL.log"
    # 口径2b: loopback RTT 512B x200
    ctrl "rtt 200 512"; sleep 4
    echo "[fw] lb-rtt:" >>"$OUT/$LABEL.log"; harvest 2 >>"$OUT/$LABEL.log"
done
echo "== end $LABEL $(date +%T) ==" | tee -a "$OUT/$LABEL.log"
