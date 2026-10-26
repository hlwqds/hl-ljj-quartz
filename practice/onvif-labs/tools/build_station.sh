#!/bin/bash
# 单站编译：./build_station.sh lab06-interop-harness（在 onvif-labs 目录下跑）
s="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../$s" || exit 9
. ~/esp/esp-idf/export.sh >/dev/null 2>&1
mkdir -p build
idf.py build > "build/build.log" 2>&1
rc=$?
echo "$s BUILD=$rc"
grep -m2 -E "error|错误" "build/build.log" || true
