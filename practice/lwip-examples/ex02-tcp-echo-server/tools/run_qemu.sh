#!/usr/bin/env bash
# ex02 QEMU 启动脚本：串口输出落 run.log，hostfwd tcp::8210-:8210
# 用法：tools/run_qemu.sh [超时秒数]   （默认 600s，timeout 到点退出码 124 属正常）
#
# 注意（CONVENTIONS §3/Batch 4）：不写 efuse `-global nvram.esp32.efuse` 行——
# 该行在本机 QEMU 上偶发导致 openeth NIC 未创建。
# 并行实验纪律：启动前如发现端口冲突，按 hostfwd 特征精确 kill，
# 禁止 pkill：
#   for p in $(pgrep -f '^/home/huanglin/.espressif/tools/qemu-xtensa'); do
#     tr '\0' ' ' < /proc/$p/cmdline | grep -q 'tcp::8210' && kill $p || true
#   done
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
cd "$(dirname "$0")/.." || exit 1
T=${1:-600}
timeout $T $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8210-:8210 \
  -nographic -no-reboot 2>&1 | tee run.log
exit 0
