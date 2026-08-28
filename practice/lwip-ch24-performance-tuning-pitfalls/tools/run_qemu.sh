#!/usr/bin/env bash
# ch24 QEMU 启动脚本：串口输出落 $LOG（默认 run.log），hostfwd 端口
# 8028(echo)/8029(ctrl)/8030(http)（8024/8025 已被并行实验进程占用）。
# 运行前请确认没有同工程旧实例：pgrep -af 'tcp::8028'
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
cd "$(dirname "$0")/.."
exec $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8028-:8888,hostfwd=tcp::8029-:9999,hostfwd=tcp::8030-:80 \
  -nographic -no-reboot "$@" 2>&1 | tee "${LOG:-run.log}"
