#!/usr/bin/env bash
# ex13 QEMU 启动脚本：串口输出落 run.log
#
# 双向拓扑对应的网络参数（SPEC §4 ex13 号段 8300/8301）：
#   - 入向命令面：hostfwd tcp::8300-:8300（宿主机 -> guest，SLIRP 唯一入向通道）
#   - 出向心跳面：guest 直连 10.0.2.2:8301 = 宿主机 loopback:8301（无需 hostfwd，
#     SLIRP 把 guest 发往 10.0.2.2 的 TCP 落到宿主 loopback 同端口）
#
# 用法：tools/run_qemu.sh [超时秒数]   （默认 600s，timeout 到点退出码 124 属正常截停）
#
# 注意（CONVENTIONS §3/Batch 4）：不写 efuse `-global nvram.esp32.efuse` 行——
# 该行在本机 QEMU 上偶发导致 openeth NIC 未创建。
# 并行实验纪律：启动前如发现端口冲突，按 hostfwd 特征精确 kill，禁止 pkill：
#   for p in $(pgrep -f '^/home/huanglin/.espressif/tools/qemu-xtensa'); do
#     tr '\0' ' ' < /proc/$p/cmdline | grep -q 'tcp::8300' && kill $p || true
#   done
QEMU_BIN=${QEMU_BIN:-~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa}
cd "$(dirname "$0")/.." || exit 1
T=${1:-600}
timeout $T $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8300-:8300 \
  -nographic -no-reboot 2>&1 | tee run.log
exit 0
