#!/usr/bin/env bash
# ex09 QEMU 启动器：串口输出落 run.log（无 hostfwd——本示例只有 guest 出向流量，
# 见 SPEC §4：guest 出连宿主 8280）。
#
# 用法：tools/run_qemu.sh [超时秒数]   （默认 90s；到点退出码 124 属正常截停）
#
# 注意：本套件统一【去掉】 efuse -global 行（Batch 4 实测该行偶发导致 openeth
# NIC 未创建，见 CONVENTIONS §3 warning）。最坏情形耗时：boot ~3.5s + 3 轮
# 尝试 ×(握手 ~1s + 逃生预算 8s + 结算间隔)≈ 40s 内收尾。
QEMU_BIN=${QEMU_BIN:-~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa}
cd "$(dirname "$0")/.." || exit 1
T=${1:-90}
timeout $T $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth \
  -nographic -no-reboot 2>&1 | tee run.log
exit 0
