#!/usr/bin/env bash
# size_report.sh — 组件化固件的存储账（ch17 §17.5.2 内存/存储评估配套）。
#
# 用法：在工程目录下  ./../tools/size_report.sh build
# 输出四层：app 总量 vs factory 分区容量 / onvif 组件归档明细 /
# main 归档明细 / 组件间 Top 占用。数据源 = idf_size.py 解析 .map。
set -euo pipefail

BUILD_DIR="${1:-build}"
MAP=$(ls "$BUILD_DIR"/*.map 2>/dev/null | head -1)
BIN=$(ls "$BUILD_DIR"/*.bin 2>/dev/null | grep -v bootloader | grep -v partition | head -1)
IDF_SIZE="$IDF_PATH/tools/idf_size.py"

if [[ -z "${IDF_PATH:-}" || ! -f "$IDF_SIZE" ]]; then
    echo "FATAL: IDF_PATH 未设或 idf_size.py 不存在（在 idf.py 环境里跑）" >&2
    exit 2
fi
if [[ -z "$MAP" ]]; then
    echo "FATAL: $BUILD_DIR 下无 .map" >&2
    exit 2
fi

echo "== APP 总量 vs 分区 =="
APP_BYTES=$(stat -c %s "$BIN" 2>/dev/null || echo 0)
echo "app_binary=$APP_BYTES bytes"
echo "factory_partition=3932160 bytes (0x3F0000 @ partitions.csv 默认布局)"
python3 - "$APP_BYTES" <<'EOF'
import sys
b = int(sys.argv[1])
cap = 3932160
print(f"app_usage={b * 100 / cap:.1f}% of factory")
EOF

echo
echo "== onvif 组件归档（text/rodata/data/bss）=="
"$IDF_SIZE" "$MAP" --archive_details libonvif.a 2>/dev/null || true

echo
echo "== main 归档 =="
"$IDF_SIZE" "$MAP" --archive_details libmain.a 2>/dev/null || true

echo
echo "== 全组件 Top 15（按 Total）=="
"$IDF_SIZE" "$MAP" --archives 2>/dev/null | sort -t, -k7 -rn 2>/dev/null | head -15 \
    || "$IDF_SIZE" "$MAP" --archives 2>/dev/null | head -15
