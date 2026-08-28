#!/usr/bin/env bash
# ch20 QEMU 启动脚本：串口输出落 run.log，hostfwd 端口 8024(http)/8025(ctrl)
# 用法：tools/run_qemu.sh [超时秒数]   （默认 600s，timeout 到点退出码 124 属正常）
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
cd "$(dirname "$0")/.."
T=${1:-600}
timeout $T $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8024-:80,hostfwd=tcp::8025-:9999 \
  -nographic -no-reboot 2>&1 | tee run.log
exit 0
