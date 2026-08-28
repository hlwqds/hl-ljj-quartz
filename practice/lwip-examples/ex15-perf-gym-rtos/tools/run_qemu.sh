#!/usr/bin/env bash
# ex15 QEMU 启动脚本：串口输出落 run.log
#
# ex15 号段 8320（SPEC §4）：全部场景走 guest 自环/自身 IP 负载 + esp_ping 出向探测，
# 无 hostfwd —— 邮箱洪水与慢回调都是固件内自动注入，主机侧零配合。
#
# 用法：tools/run_qemu.sh [超时秒数]   （默认 110s；timeout 到点退出码 124 属正常截停）
#
# 注意（CONVENTIONS §3/Batch 4）：不写 efuse `-global nvram.esp32.efuse` 行——
# 该行在本机 QEMU 上偶发导致 openeth NIC 未创建。
# 并行实验纪律：启动前如发现资源冲突，按镜像路径特征精确 kill，禁止 pkill：
#   for p in $(pgrep -f '^/home/huanglin/.espressif/tools/qemu-xtensa'); do
#     tr '\0' ' ' < /proc/$p/cmdline | grep -q 'ex15-perf-gym-rtos' && kill $p || true
#   done
QEMU_BIN=${QEMU_BIN:-~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa}
cd "$(dirname "$0")/.." || exit 1
T=${1:-110}
timeout $T $QEMU_BIN -M esp32 -m 4M \
  -drive file="${BUILD_DIR:-build}/qemu_flash.bin",if=mtd,format=raw \
  -drive file="${BUILD_DIR:-build}/qemu_efuse.bin",if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth \
  -nographic -no-reboot 2>&1 | tee "${LOG:-run.log}"
exit 0
