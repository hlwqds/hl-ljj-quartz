#!/bin/bash
# 实验 c：固定丢包率下扫描 TCP_SND_BUF / TCP_WND
. ~/esp/esp-idf/export.sh >/dev/null 2>&1
cd "$(dirname "$0")"
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa

for W in 5760 11520 23040 46080; do
  echo "=== sweep point SND_BUF=WND=$W ==="
  # 改 defaults 后必须删 sdkconfig 才生效
  sed -i "s/^CONFIG_LWIP_TCP_SND_BUF_DEFAULT=.*/CONFIG_LWIP_TCP_SND_BUF_DEFAULT=$W/;s/^CONFIG_LWIP_TCP_WND_DEFAULT=.*/CONFIG_LWIP_TCP_WND_DEFAULT=$W/" sdkconfig.defaults
  rm -f sdkconfig
  sed -i "s/^CONFIG_CH12_SWEEP_ONLY=.*/CONFIG_CH12_SWEEP_ONLY=y/" sdkconfig.defaults
  idf.py set-target esp32 >/dev/null 2>idf.py set-target esp32 >/dev/null 2>&11
  idf.py build >/dev/null 2>&1 || { echo "BUILD FAIL $W"; exit 1; }
  idf.py qemu monitor </dev/null >/dev/null 2>&1

  python3 host/recv_ch12.py bulk --port 8012 --conns 1 > logs/sweep_host_$W.log 2>&1 &
  HPID=$!
  timeout 95 $QEMU_BIN -M esp32 -m 4M \
    -drive file=build/qemu_flash.bin,if=mtd,format=raw \
    -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
    -global driver=timer.esp32.timg,property=wdt_disable,value=true \
    -nic user,model=open_eth -nographic -no-reboot > logs/sweep_guest_$W.log 2>&1
  wait $HPID 2>/dev/null
  grep -E "CH12-FACT|SWEEPDONE|ABORTED" logs/sweep_guest_$W.log | head -5
done
echo ALL-DONE
