#!/usr/bin/env bash
# ex09 宿主端 TLS 服务器一键脚本：生成自签证书并启动 openssl s_server。
#
# SLIRP 边界事实：guest 连 10.0.2.2:P 等价于宿主机连自己的 127.0.0.1:P，
# 因此 guest 出连宿主 8280 无需任何 hostfwd（SPEC §4 对 ex09 的约定）。
#
# 用法：
#   tools/run_sserver.sh                 # 首次自动生成 certs/ 后启动（前台）
#   tools/run_sserver.sh --renew         # 强制重新生成证书再启动
#   tools/run_sserver.sh --port 8280     # 自定义端口（默认 8280，ex09 号段 +0）
#   tools/run_sserver.sh --msg           # 加 -msg 打印 TLS 记录级 trace（排障用）
#
# 配合 tee 留存宿主侧日志：tools/run_sserver.sh | tee sserv.log
#
# 注意：-rev 是「按行反转回显」——收到攒齐 \n 的一行后才把该行逐字节反转发回。
# ex09 固件的探针行刻意以 \r\n 结尾正是为了喂饱这个语义。

set -euo pipefail

PORT=8280
RENEW=0
MSGFLAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --port)
            PORT="$2"
            shift 2
            ;;
        --renew)
            RENEW=1
            shift
            ;;
        --msg)
            MSGFLAG="-msg"
            shift
            ;;
        *)
            echo "unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

cd "$(dirname "$0")/.." || exit 1
mkdir -p certs

# 一次性自签证书（CN=localhost，RSA-2048，30 天；仅离线 QEMU 教学，严禁生产）。
# 换成 ECDSA 对照实验可参考 ch22：openssl ecparam -genkey -name prime256v1。
CRT=certs/sserver.crt
KEY=certs/sserver.key
if [ ! -s "$CRT" ] || [ ! -s "$KEY" ] || [ "$RENEW" -eq 1 ]; then
    echo "SSERVO-GEN cert=$CRT key=$KEY subject=/CN=localhost"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
        -subj "/CN=localhost" -keyout "$KEY" -out "$CRT" >/dev/null 2>&1
else
    echo "SSERVO-CERT reuse existing $CRT (--renew 可强制重签)"
fi

FPR=$(openssl x509 -in "$CRT" -noout -fingerprint -sha256 | cut -d= -f2)
echo "SSERVO-FP sha256=$FPR"

if ss -ltn "( sport = :$PORT )" 2>/dev/null | grep -q LISTEN; then
    echo "SSERVO-LISTEN port=$PORT FAILED errno=98 (已被占用：ss -ltnp 归属排查)" >&2
    exit 1
fi

echo "SSERVO-READY mode=rev port=$PORT tls=tls1_2 waiting ..."
# shellcheck disable=SC2086
exec openssl s_server -accept "$PORT" -rev -tls1_2 $MSGFLAG \
    -cert "$CRT" -key "$KEY" -no_ign_eof
