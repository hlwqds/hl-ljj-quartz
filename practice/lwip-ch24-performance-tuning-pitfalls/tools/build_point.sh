#!/usr/bin/env bash
# 用指定预设重建镜像并手工合并 QEMU flash（绕开 idf.py qemu 偶发不更新镜像的坑）
# 用法: build_point.sh <preset-name>
set -eu
cd "$(dirname "$0")/.."
. ~/esp/esp-idf/export.sh >/dev/null 2>&1
cp "configs/$1.sdkdef" sdkconfig.defaults
rm -f sdkconfig
idf.py build >/tmp/ch24_build.log 2>&1 || { grep -E " error " /tmp/ch24_build.log | head; exit 1; }
( cd build && python -m esptool --chip esp32 merge-bin \
    -o qemu_flash.bin --pad-to-size 4MB @flash_args >/dev/null 2>&1 )
echo "build_point $1 ok $(grep -m1 '__TIME__' /dev/null; date +%T)"
