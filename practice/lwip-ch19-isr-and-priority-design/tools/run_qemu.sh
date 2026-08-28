#!/usr/bin/env bash
# ch19 QEMU 启动脚本：串口输出落 run.log，hostfwd 端口 8022(echo)/8023(ctrl)
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
cd "$(dirname "$0")/.."
exec $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8022-:8888,hostfwd=tcp::8023-:9999 \
  -nographic -no-reboot "$@" 2>&1 | tee run.log
