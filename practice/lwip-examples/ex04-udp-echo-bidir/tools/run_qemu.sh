#!/usr/bin/env bash
# ex04 QEMU 启动脚本：串口输出落 run.log，hostfwd 端口 8230/udp（入向主服务）
# 用法：tools/run_qemu.sh [超时秒数]   （默认 600s，timeout 到点退出码 124 属正常）
#
# 注意：按 SPEC §2 / CONVENTIONS Batch 4 教训，本脚本刻意【不含】
# `-global driver=nvram.esp32.efuse,...` 行——该行在本机 QEMU 上偶发导致
# openeth NIC 未创建（启动警告 "was not created"）。若见 NIC 未创建先查这里。
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
cd "$(dirname "$0")/.."
T=${1:-600}
timeout $T $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=udp::8230-:8230 \
  -nographic -no-reboot 2>&1 | tee run.log
exit 0
