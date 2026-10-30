#!/usr/bin/env bash
# collect.sh —— WiFi airtime 真机采集脚本（树莓派/ Linux，配合 ch02-airtime-probe）
#
# 【状态：待真机】本脚本尚未上真树莓派验证；在 Windows 宿主上仅用 iw 桩脚本
# （PATH 注入假 iw 回放 fixtures 样例）做过逻辑干跑，见工程 README。
#
# 用法：
#   ./collect.sh [-i wlan0] [-o airtime.csv] [-n 轮数] [-t 间隔秒]
#     -i  接口名（默认 wlan0）
#     -o  CSV 输出路径（默认 ./airtime.csv，不存在则写表头，之后追加）
#     -n  采集轮数，0 表示无限循环（默认 0）
#     -t  每轮间隔秒（默认 30）
#
#   依赖：iw、awk、date。iw 的 survey/station dump 需要 root（CAP_NET_ADMIN），
#   非 root 运行会提示但仍继续（便于干跑）。
#
#   每轮执行 iw dev $IFACE survey dump 与 iw dev $IFACE station dump，
#   逐块提取字段，追加成 CSV 行：survey 每个信道块一行、station 每个站点一行，
#   kind 列区分；时间列统一归一到 µs（iw 显示 ms ×1000）。
#
# crontab 示例（每 5 分钟采一轮，追加到 /home/pi/airtime.csv）：
#   */5 * * * * /home/pi/wifi-airtime-labs/ch02-airtime-probe/collect.sh -i wlan0 -o /home/pi/airtime.csv -n 1 >> /home/pi/airtime-collect.log 2>&1
#
# 采集完成后用解析器看报告：
#   ~/zig/zig cc -O2 -o airtime_probe airtime_probe.c   # 或系统 cc
#   iw dev wlan0 survey dump   > /tmp/s.txt ; iw dev wlan0 station dump > /tmp/t.txt
#   ./airtime_probe /tmp/s.txt /tmp/t.txt

set -u

IFACE="wlan0"
OUT="airtime.csv"
ROUNDS=0
INTERVAL=30

usage() {
    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while getopts ":i:o:n:t:h" opt; do
    case "$opt" in
    i) IFACE="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    n) ROUNDS="$OPTARG" ;;
    t) INTERVAL="$OPTARG" ;;
    h) usage ;;
    *) echo "未知参数：-$OPTARG（-h 看用法）" >&2; exit 2 ;;
    esac
done

if ! command -v iw >/dev/null 2>&1; then
    echo "错误：找不到 iw 命令（真机请安装 iw 包）" >&2
    exit 3
fi

if [ "$(id -u)" != "0" ]; then
    echo "提示：非 root 运行，iw survey/station dump 通常会失败（需要 CAP_NET_ADMIN）" >&2
fi

CSV_HEADER="ts,iface,kind,key,noise_dbm,in_use,active_us,busy_us,extbusy_us,rx_us,tx_us,busy_pct,signal_dbm,tx_packets,tx_bytes,tx_retries,tx_failed,retry_pct,tx_bitrate_mbps,warn"
if [ ! -s "$OUT" ]; then
    echo "$CSV_HEADER" >"$OUT"
fi

# survey dump → 每个信道块一行
survey_once() {
    iw dev "$IFACE" survey dump 2>>"${OUT}.err" | awk -v ts="$1" -v ifc="$IFACE" '
        function flush() {
            if (freq == "") return
            bp = (active != "" && active + 0 > 0) ? sprintf("%.2f", busy * 100 / active) : ""
            warn = (bp != "" && busy * 100 / active > 70) ? "busy" : ""
            inuse = (inuse == 1) ? "yes" : "no"
            printf "%s,%s,survey,%s,%s,%s,%s,%s,%s,%s,%s,%s,,,,,,,,%s\n", \
                ts, ifc, freq, (noise == "" ? "" : noise), inuse, \
                (active == "" ? "" : active * 1000), (busy == "" ? "" : busy * 1000), \
                (ext == "" ? "" : ext * 1000), (rx == "" ? "" : rx * 1000), \
                (tx == "" ? "" : tx * 1000), bp, warn
            freq = noise = ""; inuse = ""; active = busy = ext = rx = tx = ""
        }
        $1 == "frequency:" { flush(); freq = $2; next }
        $1 == "in" && $2 == "use:" { inuse = ($3 == "yes") ? 1 : 0; next }
        $1 == "noise:" { noise = $2; next }
        $1 == "channel" && $2 == "active" && $3 == "time:" { active = $4; next }
        $1 == "channel" && $2 == "busy" && $3 == "time:" { busy = $4; next }
        $1 == "channel" && $2 == "receive" && $3 == "time:" { rx = $4; next }
        $1 == "channel" && $2 == "transmit" && $3 == "time:" { tx = $4; next }
        $1 == "extended" && $2 == "channel" && $3 == "busy" && $4 == "time:" { ext = $5; next }
        END { flush() }
    ' >>"$OUT"
}

# station dump → 每个站点一行
station_once() {
    iw dev "$IFACE" station dump 2>>"${OUT}.err" | awk -v ts="$1" -v ifc="$IFACE" '
        function flush() {
            if (mac == "") return
            rp = (txp != "" && txp + 0 > 0) ? sprintf("%.2f", txr * 100 / txp) : ""
            warn = (rp != "" && txr * 100 / txp > 30) ? "retry" : ""
            printf "%s,%s,station,%s,,,,,,,,,%s,%s,%s,%s,%s,%s,%s,%s\n", \
                ts, ifc, mac, (sig == "" ? "" : sig), \
                (txp == "" ? "" : txp), (txb == "" ? "" : txb), \
                (txr == "" ? "" : txr), (txf == "" ? "" : txf), rp, txbr, warn
            mac = ""; sig = ""; txp = txb = txr = txf = txbr = ""
        }
        /^Station[ \t]/ { flush(); mac = $2; next }
        $1 == "signal:" { sig = $2; next }
        $1 == "tx" && $2 == "packets:" { txp = $3; next }
        $1 == "tx" && $2 == "bytes:" { txb = $3; next }
        $1 == "tx" && $2 == "retries:" { txr = $3; next }
        $1 == "tx" && $2 == "failed:" { txf = $3; next }
        $1 == "tx" && $2 == "bitrate:" {
            if ($4 == "kBit/s") txbr = sprintf("%.3f", $3 / 1000)
            else if ($4 == "GBit/s") txbr = sprintf("%.1f", $3 * 1000)
            else txbr = $3
            next
        }
        END { flush() }
    ' >>"$OUT"
}

n=0
echo "开始采集：iface=$IFACE out=$OUT rounds=${ROUNDS}(0=无限) interval=${INTERVAL}s（Ctrl-C 停止）"
while [ "$ROUNDS" -eq 0 ] || [ "$n" -lt "$ROUNDS" ]; do
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    survey_once "$ts"
    station_once "$ts"
    n=$((n + 1))
    [ "$ROUNDS" -eq 0 ] && [ "$INTERVAL" -gt 0 ] && sleep "$INTERVAL"
done
echo "采集结束：共 $n 轮，数据在 $OUT"
