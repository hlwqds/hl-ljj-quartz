#!/usr/bin/env bash
# ex12 QEMU 启动器：串口输出落 run.log。纯观测示例：无 hostfwd、无外部工具依赖。
# 套件标准形态：不带 efuse `-global` 行（该行在本机 QEMU 上偶发导致 openeth NIC
# 未创建，见 practice/lwip-labs/CONVENTIONS.md Batch 4）。
# 用法：tools/run_qemu.sh [超时秒数]（默认 80s）
#   起播约需 3s，仪表盘周期 30s：80s 可稳定收进 frame1/frame2 两帧完整快照；
#   timeout 到点退出码 124 属正常截停，固件侧由脚本 SIGTERM 精确结束本进程。
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
cd "$(dirname "$0")/.." || exit 1
T=${1:-80}
timeout $T $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth \
  -nographic -no-reboot 2>&1 | tee run.log
exit 0
