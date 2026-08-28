#!/bin/bash
# ch18 以太网对照实验一键运行脚本
# 唯一性标记：-L 指向本项目 tools/ 目录（用于精确 kill，不误伤并行作者的 QEMU）
set -u
PROJ=/home/huanglin/code/quartz/practice/lwip-ch18-esp32-wifi-lwip-integration
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
cd "$PROJ"

# 防御：若本工程旧实例还在，按唯一 -L 路径特征杀掉（只杀 cmdline 含该绝对路径的进程）
for pid in $(pgrep qemu-system-xte 2>/dev/null); do
    if tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | grep -q "$PROJ/tools"; then
        kill "$pid" 2>/dev/null; sleep 1
    fi
done

rm -f run.log bench_out.txt qemu.pid

timeout 300 $QEMU_BIN -M esp32 -m 4M \
    -drive file=build/qemu_flash.bin,if=mtd,format=raw \
    -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
    -global driver=nvram.esp32.efuse,property=drive,value=efuse \
    -global driver=timer.esp32.timg,property=wdt_disable,value=true \
    -nic user,model=open_eth,hostfwd=tcp::8050-:8888 \
    -L "$PROJ/tools" \
    -nographic -no-reboot < /dev/null > run.log 2>&1 &
echo $! > qemu.pid
QPARENT=$(cat qemu.pid)

# 等 DHCP 完成（最长 20s）
for i in $(seq 1 40); do
    grep -q "ETH netif impl" run.log && break
    sleep 0.5
done

{
echo "########## PHASE 1: BASELINE ##########"
date +%H:%M:%S.%N
./tools/bench.py rtt
date +%H:%M:%S.%N
./tools/bench.py bulk
date +%H:%M:%S.%N

echo "########## SWITCH: install lossy linkoutput ##########"
./tools/bench.py lossy-on
sleep 1

echo "########## PHASE 2: LOSSY 10%% TX FRAME DROP ##########"
date +%H:%M:%S.%N
./tools/bench.py rtt
date +%H:%M:%S.%N
./tools/bench.py bulk
date +%H:%M:%S.%N

echo "########## UNWRAP + guest counters ##########"
./tools/bench.py lossy-off
sleep 1
} >> bench_out.txt 2>&1

# 精确清理：只杀本工程实例（cmdline 含 $PROJ/tools）
for pid in $(pgrep qemu-system-xte 2>/dev/null); do
    if tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | grep -q "$PROJ/tools"; then
        kill "$pid" 2>/dev/null
    fi
done
kill $QPARENT 2>/dev/null
echo "experiment done"
