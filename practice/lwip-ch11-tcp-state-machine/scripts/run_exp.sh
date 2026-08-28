#!/usr/bin/env bash
# 启动一次 ch11 实验：起 QEMU（后台）→ 跑主机驱动脚本 → 按特征精确杀 QEMU。
# 用法: ./run_exp.sh <phase> <timeout_s> [build_dir]
#   phase ∈ {a_active, a_passive, b, c, d}
set -u

PHASE=${1:?phase}
TIMEOUT=${2:-60}
BUILD=${3:-build}
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$DIR/logs/exp_${PHASE}.log"

mkdir -p "$DIR/logs"

cd "$DIR"
$QEMU_BIN -M esp32 -m 4M \
  -drive file=$BUILD/qemu_flash.bin,if=mtd,format=raw \
  -drive file=$BUILD/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8014-:8814,hostfwd=tcp::9014-:8813 \
  -nographic -no-reboot > "$LOG" 2>&1 &
QPID=$!
echo "qemu pid=$QPID log=$LOG"

cleanup() {
  # 精确按 PID 终止，禁止 pkill（存在并行作者实例）
  kill "$QPID" 2>/dev/null
  sleep 1
  kill -9 "$QPID" 2>/dev/null
}
trap cleanup EXIT

sleep 2
if grep -qE "(could not set up host forwarding|Failed to add)" "$LOG"; then
  echo "ERROR: hostfwd conflict, abort"; exit 2
fi

timeout "$TIMEOUT" python3 scripts/exp11.py --phase "$PHASE"
RC=$?
echo "driver rc=$RC; tail of log:"
tail -n +1 "$LOG" | grep -E "PCBS|PCBD|INJECT|srv|GOT_IP|GW\[" | tail -40
exit $RC
