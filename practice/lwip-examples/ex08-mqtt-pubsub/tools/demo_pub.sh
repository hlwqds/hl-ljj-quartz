#!/usr/bin/env bash
# ex08 下行消息触发器：向 demo/topic 发布一条 QoS1 消息（guest 已订阅该主题）
#
# 用法：
#   tools/demo_pub.sh "hello from host"          # 自定义消息内容
#
# 可用环境变量覆盖默认目标：
#   TOPIC=demo/topic HOST=127.0.0.1 PORT=1883 tools/demo_pub.sh "msg"
set -eu
MSG="${1:-hello-from-host}"
TOPIC="${TOPIC:-demo/topic}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-1883}"

exec mosquitto_pub -h "$HOST" -p "$PORT" -t "$TOPIC" -q 1 -m "$MSG"
