#!/bin/bash
# 按公约第 3 节的 QEMU 直跑模板；hostfwd 用章号 8020（TCP echo + UDP flood）
cd "$(dirname "$0")/.."
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout "${TMO:-90}" $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8020-:8888,hostfwd=udp::8020-:8020 \
  -nographic -no-reboot 2>&1 | tee run.log
