#!/usr/bin/env bash
# ex05 QEMU 启动器：串口输出 tee 到 run.log；hostfwd tcp::8240-:80（套件 ex05 号段）。
#
# 用法：tools/run_qemu.sh [超时秒数]    （默认 300s）
#   - 到点 timeout 截停退出码 124 属正常结束方式；
#   - 去掉了 efuse -global 行：该行在本机 QEMU 偶发导致 openeth NIC 未创建
#     （CONVENTIONS Batch 4），示例套件统一使用本形态；
#   - 启动后若日志出现 "could not set up host forwarding" 说明宿主 8240 被占，先查占用。
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
cd "$(dirname "$0")/.." || exit 1
T=${1:-300}
timeout $T $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8240-:80 \
  -nographic -no-reboot 2>&1 | tee run.log
exit 0
