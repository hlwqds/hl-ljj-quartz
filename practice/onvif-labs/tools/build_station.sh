#!/bin/bash
# 单站编译：./build_station.sh lab06-interop-harness（在 onvif-labs 目录下跑）
s="$1"
cd "$(dirname "$0")/../$s" || exit 9
. ~/esp/esp-idf/export.sh >/dev/null 2>&1
idf.py build > "/tmp/$s-build.log" 2>&1
rc=$?
echo "$s BUILD=$rc"
grep -m2 -E "error|错误" "/tmp/$s-build.log" || true
