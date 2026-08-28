#!/usr/bin/env bash
# ex16 QEMU 启动脚本：串口输出落 LOG（默认 run.log）
#
# ex16 号段 8330（SPEC §4）：hostfwd tcp::8330-:8330（case0 入向命令口 / 手动探针）；
# 可选宿主反射器走 guest 出连 10.0.2.2:8331（无需 hostfwd）。
# 负载主路径默认 guest 内 127.0.0.1 自环（Batch 8 教训：严禁目的地址用自身 IP）。
#
# 用法：tools/run_qemu.sh [超时秒数]   （默认 100s；timeout 退出码 124 属正常截停）
#
# 注意（CONVENTIONS §3/Batch 4）：不写 efuse `-global nvram.esp32.efuse` 行——
# 该行在本机 QEMU 上偶发导致 openeth NIC 未创建。
# 并行实验纪律：按镜像路径特征精确 kill，禁止 pkill：
#   for p in $(pgrep -f '^/home/huanglin/.espressif/tools/qemu-xtensa'); do
#     tr '\0' ' ' < /proc/$p/cmdline | grep -q 'ex16-zero-copy-cases' && kill $p || true
#   done
QEMU_BIN=${QEMU_BIN:-~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa}
cd "$(dirname "$0")/.." || exit 1
T=${1:-100}
timeout $T $QEMU_BIN -M esp32 -m 4M \
  -drive file="${BUILD_DIR:-build}/qemu_flash.bin",if=mtd,format=raw \
  -drive file="${BUILD_DIR:-build}/qemu_efuse.bin",if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8330-:8330 \
  -nographic -no-reboot 2>&1 | tee "${LOG:-run.log}"
exit 0
