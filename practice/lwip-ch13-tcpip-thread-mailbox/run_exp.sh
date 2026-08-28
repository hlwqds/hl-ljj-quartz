#!/bin/bash
# ch13 实验：一键复现。启动 QEMU(hostfwd 8015)，观察日志，
# 在实验 C(3s 卡死)窗口内从主机侧打 ping/建连探针，结束后精确 kill。
set -u
cd "$(dirname "$0")"
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa

rm -f run.log probe_ping.log probe_tcp.log
timeout 90 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8015-:8888 \
  -nographic -no-reboot > run.log 2>&1 &
QPID=$!
echo "qemu pid=$QPID"

# 等待实验 C 开始标记（基线 ping 完成后即将投递 stall 回调）
for i in $(seq 1 600); do
  grep -q "\[C\] baseline done" run.log && break
  kill -0 $QPID 2>/dev/null || { echo "qemu exited early"; exit 1; }
  sleep 0.05
done

# 卡死窗口内：主机 -> guest 的 TCP 建连+回显探针（经 hostfwd，SLIRP 不支持入向 ICMP）
python3 - <<'EOF' > probe_tcp.log 2>&1 &
import socket, time
end = time.time() + 9
while time.time() < end:
    t = time.time()
    try:
        s = socket.create_connection(("127.0.0.1", 8015), timeout=8)
        s.sendall(b"hello-ch13")
        d = s.recv(64)
        print(f"{time.strftime('%H:%M:%S')} connect OK rtt={time.time()-t:.3f}s data={d!r}")
        s.close()
    except Exception as e:
        print(f"{time.strftime('%H:%M:%S')} connect FAIL/STALL {type(e).__name__} rtt={time.time()-t:.3f}s")
    time.sleep(0.3)
EOF
sleep 9

# 等实验 D 与收尾标记
for i in $(seq 1 600); do
  grep -q "== ch13 lab all phases done" run.log && break
  sleep 0.1
done

kill $QPID 2>/dev/null
wait $QPID 2>/dev/null
echo DONE
