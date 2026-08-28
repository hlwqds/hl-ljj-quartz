#!/usr/bin/env bash
# ch21 实验编排脚本：负责两类宿主机动作（SIGSTOP 冻结 / SIGTERM 硬杀+重启），
# 其余全部由固件自驱动。进程管理一律用记录下的精确 PID，禁止 pkill。
set -u
ROOT=/home/huanglin/code/quartz/practice/lwip-ch21-mqtt
RUN=$ROOT/run
SCR=$ROOT/scripts
QEMU_BIN="$HOME/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa"
FREEZE_TOTAL_S=14          # 固件约定：arm 后 ~14s CONT；积压须在 outbox 30s 过期前排空
HARDKILL_RESTART_S=6       # 固件已打印该值，这里保持一致
GLOBAL_TMO=400

mark() { echo "HOST_MARK $(date +%s.%N) $*"; }

# ---------------- 启动 broker ----------------
# 单实例守卫：历史孤儿桥/孤儿 qemu 会产生同 id 互踢风暴（详见文章排坑记录）
if pgrep -f "$SCR/mqtt_bridge.py" >/dev/null 2>&1; then
    echo "FATAL: stray mqtt_bridge.py already running:"; pgrep -af "$SCR/mqtt_bridge.py"; exit 1
fi
rm -f "$RUN/mosquitto.pid" "$RUN/bridge.jsonl" "$RUN/qemu.log"   # 旧日志会让 marker 匹配到上一轮！
# 若上一轮残留或并行作者持有 1883，先等它释放（最多 20s）
for i in $(seq 200); do ss -ltn 2>/dev/null | grep -q ':1883 ' || break; sleep 0.1; done
if ss -ltn 2>/dev/null | grep -q ':1883 '; then echo "FATAL: port 1883 busy by another process"; exit 1; fi
mosquitto -c "$SCR/mosquitto_lab.conf" -v > "$RUN/mosquitto.log" 2>&1 &
BROKER_PID=$!
for i in $(seq 60); do ss -ltnp 2>/dev/null | grep "pid=$BROKER_PID," | grep -q ':1883 ' && break; sleep 0.1; done
if ! ss -ltnp 2>/dev/null | grep "pid=$BROKER_PID," | grep -q ':1883 '; then
    echo "FATAL: our mosquitto did not take 1883"; tail -3 "$RUN/mosquitto.log"; exit 1
fi
mark BROKER_UP pid=$BROKER_PID

python3 "$SCR/mqtt_bridge.py" --jsonl "$RUN/bridge.jsonl" > "$RUN/bridge.stdout" 2>&1 &
BRIDGE_PID=$!
mark BRIDGE_UP pid=$BRIDGE_PID

# ---------------- 启动 QEMU ----------------
start_qemu() {  # $1 = "with_efuse" | "no_efuse"
    local efuse_args=()
    [ "${1:-with_efuse}" = "with_efuse" ] && efuse_args=(
        -drive file="$ROOT/build/qemu_efuse.bin",if=none,format=raw,id=efuse
        -global driver=nvram.esp32.efuse,property=drive,value=efuse)
    timeout $GLOBAL_TMO "$QEMU_BIN" -M esp32 -m 4M \
        -drive file="$ROOT/build/qemu_flash.bin",if=mtd,format=raw \
        "${efuse_args[@]}" \
        -global driver=timer.esp32.timg,property=wdt_disable,value=true \
        -nic user,model=open_eth -nographic -no-reboot > "$RUN/qemu.log" 2>&1 &
    QEMU_PID=$!
}

start_qemu with_efuse
sleep 12
if ! grep -qE 'GOT_IP|waiting for DHCP' "$RUN/qemu.log"; then
    if grep -qE 'was not created|abort\(\)|Guru Meditation' "$RUN/qemu.log"; then
        echo "RETRY: NIC 未创建，去掉 efuse 全局绑定重跑"
        kill "$QEMU_PID" 2>/dev/null; sleep 1
        start_qemu no_efuse
    fi
fi
mark QEMU_UP pid=${QEMU_PID:-0}

wait_log() {  # $1 pattern, $2 timeout_s
    local s0=$(date +%s)
    while ! grep -q "$1" "$RUN/qemu.log" 2>/dev/null; do
        sleep 0.2
        local now=$(date +%s)
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then echo "QEMU died waiting $1"; return 1; fi
        if [ $((now - s0)) -gt "${2:-120}" ]; then echo "TIMEOUT waiting $1"; return 1; fi
    done
    return 0
}

cleanup() {
    mark CLEANUP_BEGIN
    kill "$QEMU_PID"   2>/dev/null
    kill "$BRIDGE_PID" 2>/dev/null
    kill "$BROKER_PID" 2>/dev/null
    sleep 0.5
    kill -9 "$QEMU_PID" "$BRIDGE_PID" 2>/dev/null
    mark DONE
}

trap cleanup EXIT

# ---------------- 阶段 C：冻结 ----------------
if wait_log APP_PHASE_FREEZE_ARMED 120; then
    kill -STOP "$BROKER_PID"
    mark BROKER_SIGSTOP
    sleep $FREEZE_TOTAL_S
    kill -CONT "$BROKER_PID"
    mark BROKER_SIGCONT
else
    echo "SKIP freeze phase (marker missing)"
fi

# ---------------- 阶段 D：硬杀 + 重启 ----------------
if wait_log APP_PHASE_HARDKILL_ARMED 320; then
    kill -TERM "$BROKER_PID"
    mark BROKER_TERM
    sleep $HARDKILL_RESTART_S
    mosquitto -c "$SCR/mosquitto_lab.conf" -v >> "$RUN/mosquitto.log" 2>&1 &
    BROKER_PID=$!
    for i in $(seq 50); do ss -ltnp 2>/dev/null | grep "pid=$BROKER_PID," | grep -q ':1883 ' && break; sleep 0.1; done
    mark BROKER_RESTARTED pid=$BROKER_PID
else
    echo "SKIP hardkill phase (marker missing)"
fi

# ---------------- 收尾 ----------------
if wait_log APP_ALL_DONE 240; then
    mark GUEST_ALL_DONE
fi
sleep 1
exit 0
