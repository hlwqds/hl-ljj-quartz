#!/usr/bin/env bash
# ex08 宿主侧 broker 管理脚本（mosquitto 需已安装，见 README 安装小节）
#
# 用法：
#   tools/run_broker.sh start     启动（后台，配置 tools/mosquitto.conf）
#   tools/run_broker.sh stop      按 pidfile 精确停止（禁止 pkill，套件公约）
#   tools/run_broker.sh status    查看 PID 与端口
#   tools/run_broker.sh restart   = stop && start
#
# 设计要点：
#   - 日志与 pidfile 放 /tmp/ex08-*，工程目录只留代码；
#   - 启动前检查 1883 端口归属：并行实验可能有别人的进程占位，
#     不是本脚本的实例就拒绝启动并提示排查（CONVENTIONS Batch 6 教训）；
#   - 等到端口真正 LISTEN 才报成功。
set -u

CONF="$(cd "$(dirname "$0")" && pwd)/mosquitto.conf"
PID_FILE=/tmp/ex08-mosquitto.pid
LOG_FILE=/tmp/ex08-mosquitto.log
PORT=1883

port_owner() { ss -ltnp "sport = :$PORT" 2>/dev/null | tail -n +2; }

alive_pid() {
    [ -f "$PID_FILE" ] || return 1
    local p; p=$(cat "$PID_FILE")
    kill -0 "$p" 2>/dev/null && { echo "$p"; return 0; } || return 1
}

do_start() {
    if p=$(alive_pid); then
        echo "already running: pid=$p (port $PORT listening)" ; exit 0
    fi
    if port_owner | grep -q .; then
        echo "ERROR: port $PORT occupied by another process:" ; port_owner
        echo "hint: run 'tools/run_broker.sh status' or stop the foreign process first."
        exit 1
    fi
    nohup mosquitto -c "$CONF" >"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    for _ in $(seq 1 25); do               # 最多等 ~5s 到 LISTEN
        if port_owner | grep -q ":$PORT"; then
            echo "broker started: pid=$(cat "$PID_FILE") conf=$CONF log=$LOG_FILE"
            return 0
        fi
        if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "ERROR: mosquitto exited during startup:" ; cat "$LOG_FILE"
            rm -f "$PID_FILE"; exit 1
        fi
        sleep 0.2
    done
    echo "WARN: started but port $PORT not seen LISTEN within 5s, check $LOG_FILE"
}

do_stop() {
    if p=$(alive_pid); then
        kill -TERM "$p"
        for _ in $(seq 1 50); do           # 最多等 5s 退出
            kill -0 "$p" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$p" 2>/dev/null && echo "WARN: pid=$p still alive after SIGTERM" \
                                    || echo "broker stopped: pid=$p"
        rm -f "$PID_FILE"
    else
        echo "not running (no live pidfile)"
    fi
}

case "${1:-}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; do_start ;;
    status)
        if p=$(alive_pid); then echo "running: pid=$p"; else echo "not running"; fi
        port_owner || true ;;
    *) echo "usage: $0 {start|stop|status|restart}"; exit 2 ;;
esac
