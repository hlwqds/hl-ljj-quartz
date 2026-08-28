#!/usr/bin/env bash
# ex08 断线重连全流程演示（一次跑完，产出三段真实证据）：
#   1) 连接 + 订阅确认 + 自回显计数消息；
#   2) 宿主侧手动/脚本触发的下行消息（tools/demo_pub.sh）经 broker 进 guest；
#   3) SIGTERM 杀 broker -> DISCONNECTED -> 离线期 QoS1 消息进 outbox ->
#      重启 broker -> 自动重连 -> 重新订阅 -> 排空积压恢复计数；
#   4) 尾声 SIGKILL QEMU（无 MQTT DISCONNECT）-> broker 代发遗嘱 demo/lwt，
#      由全程驻留的 mosquitto_sub 观察者捕获 LWT 证据。
#
# 运行前提：
#   idf.py build && idf.py qemu monitor </dev/null || true  （生成 qemu_flash.bin）
#
# 用法：tools/demo_reconnect.sh [总预算秒数，默认 150；各等待步共享该预算]
set -u
cd "$(dirname "$0")/.." || exit 1

QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
TOTAL_S=${1:-150}
WATCH_LOG=/tmp/ex08-broker-view.log
STAMP() { date +%H:%M:%S; }
SECONDS=0

budget_s() {  # 总预算减去已耗时间，至少留 3s
    local left=$((TOTAL_S - SECONDS))
    [ "$left" -lt 3 ] && left=3
    echo "$left"
}

wait_for_line() {  # wait_for_line <文件> <正则> <最大秒>
    local f=$1 re=$2 tmax=$3 i=0
    while [ $i -lt $((tmax * 5)) ]; do
        grep -qE "$re" "$f" 2>/dev/null && return 0
        sleep 0.2; i=$((i + 1))
    done
    echo "[orchestrator] TIMEOUT waiting '$re' in $f (${tmax}s)"; return 1
}

echo "=== ex08 demo-reconnect begin $(STAMP) ==="

# 0) broker 就位
tools/run_broker.sh start || exit 1

# 1) broker 视角观察者：全程记录所有 demo/# 报文（含最后的 LWT）
mosquitto_sub -h 127.0.0.1 -p 1883 -t 'demo/#' -v > "$WATCH_LOG" &
SUB_PID=$!

# 2) 起跑 QEMU（日志直写 run.log，精确掌握 PID；禁止 pkill 的原因见 README）
: > run.log
$QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth \
  -nographic -no-reboot > run.log 2>&1 &
QPID=$!
trap 'kill -9 $QPID $SUB_PID 2>/dev/null; tools/run_broker.sh stop' EXIT
echo "[orchestrator] qemu pid=$QPID  mosquitto_sub pid=$SUB_PID"

wait_for_line run.log '\$\$\$ READY' 20    || exit 1
wait_for_line run.log 'EVT CONNECTED n=1' 15 || exit 1
wait_for_line run.log 'EVT SUBSCRIBED'     10 || exit 1
sleep 7                                    # 让 2~3 条自回显计数流过去

# 3) 下行消息两连发（宿主 -> guest）
echo "[orchestrator] >>> demo_pub hello-from-host $(STAMP)"
tools/demo_pub.sh "hello-from-host @ $(STAMP)"
sleep 2
tools/demo_pub.sh "second downlink"
sleep 4

# 4) 正常段收尾 -> 杀 broker（SIGTERM：mosquitto 收尾发 FIN，guest 秒感知）
echo "[orchestrator] >>> killing broker (SIGTERM) $(STAMP)"
tools/run_broker.sh stop
wait_for_line run.log 'EVT DISCONNECTED' 10 || exit 1
sleep 11                                   # 经历至少一次固定间隔重连失败（默认 10s）

# 5) 拉回 broker -> 观察重连成功 + 重新订阅 + outbox 排空
# 注意锚定具体事件序号（n=2/#2）：宽泛正则会命中断连前的第 1 次事件秒过。
echo "[orchestrator] >>> restarting broker $(STAMP)"
tools/run_broker.sh start || exit 1
wait_for_line run.log 'CONNECTED #2 session_present' 60 || exit 1
wait_for_line run.log 'EVT CONNECTED n=2' 10            || exit 1
sleep 16                                   # 等 PUBACK 追平、重发排空、计数恢复

# 复核：两次订阅确认 + 最近几条 publish 的 outbox 已被排干（幂等重订阅生效）
subs=$(grep -c 'EVT SUBSCRIBED' run.log || true)
if [ "${subs:-0}" -lt 2 ]; then
    echo "[orchestrator] FATAL: SUBSCRIBED confirmations=$subs (<2)"
    exit 1
fi
echo "[orchestrator] resubscribed=$subs, publish/outbox tail:"
grep -E '\[APP\] PUBLISH' run.log | tail -4

# 6) 遗嘱实验：SIGKILL QEMU —— TCP 直接蒸发且没有 DISCONNECT 报文，
#    broker 应代发 LWT 到 demo/lwt（观察者视角落在 WATCH_LOG）
kill -9 $QPID 2>/dev/null
wait $QPID 2>/dev/null                       # 吞掉 bash 的"已杀死"通知
echo "[orchestrator] >>> qemu killed ($QPID), waiting LWT at broker side"
sleep 4

kill $SUB_PID 2>/dev/null
wait $SUB_PID 2>/dev/null
tools/run_broker.sh stop
trap - EXIT

echo "=== guest key lines ==="
grep -E '\$\$\$|GOT_IP|\[MQTT\]|PUBLISH|rejected' run.log | head -80
echo "=== broker view tail ($WATCH_LOG) ==="
tail -12 "$WATCH_LOG"
echo "=== done $(STAMP) ==="
