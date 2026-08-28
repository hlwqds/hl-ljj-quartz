# lwIP 深度解析（二十三）实验：调试工具箱

破案实战 = 主实验：复现并解剖 ch22 悬案②「guest 内 loopback 明文服务仅第一条连接可用」。
辅以「慢回声全链路取证」（ping 基线 → hostfwd python/nc 探针 → tcpdump -i lo → gdb attach）。

## 构建 / 运行

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch23-debugging-toolbox
idf.py set-target esp32        # 仅首次
idf.py build
idf.py qemu monitor < /dev/null || true   # 生成 qemu_flash.bin（monitor 因无 TTY 报错可忽略）
ls build/qemu_flash.bin build/qemu_efuse.bin

QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 95 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot 2>&1 | tee runlogs/case.log
```

## 三条抓包路径的宿主机侧操作（keepalive 窗口期执行）

```bash
# (a) loopback 抓包：hostfwd 流量落宿主机 lo；同时 guest 内 [ip4in] 打印同一流量的协议栈视角
sudo timeout 14 tcpdump -i lo -nn tcp port 8031 -c 60 -w /tmp/ch23.pcap &
python3 tools/host_probe.py 6     # 定时探针：connect/echo RTT
tcpdump -nn -r /tmp/ch23.pcap | head

# (b)/(c) 观测点编在固件里：
#   LWIP_HOOK_IP4_INPUT -> ch23_ip4_input_hook()   （RX/IP 层，loopback 也可见）
#   netif->linkoutput   -> counting_linkoutput()   （TX/驱动层，只有出网卡的流量）

# gdb 巡检（另一种启动方式：把上面 QEMU 加 -s 且不要 timeout 太短）
xtensa-esp32-elf-gdb -batch -x tools/ch23_inspect.gdb build/lwip_ch23_debugging_toolbox.elf
```

## LWIP_DEBUG 变体构建

```bash
cp sdkconfig.defaults sdkconfig.defaults.keep
cp sdkconfig.defaults.debug sdkconfig.defaults
rm -f sdkconfig && idf.py build && cd build \
  && python -m esptool --chip esp32 merge-bin -o qemu_flash.bin --pad-to-size 4MB @flash_args
# TCP_RST_DEBUG 由根 CMakeLists 的 -include main/ch23_inject.h 编译期注入点亮
# 还原：mv sdkconfig.defaults.keep 回来，rm sdkconfig 重生成
```

## 输出

runlogs/ 下为各次真实运行日志：

- `run2-case.log` 默认配置完整破案日志（含 stats_display 全表）
- `run3-host.log` 带 hostfwd + [-s] 的窗口期日志（宿主机工具接力用）
- `run5-debug.log` CONFIG_LWIP_DEBUG=y 变体：`tcp_listen_input: listen backlog exceeded`
- `run4-gdb-start.log` -S 暂停起步 + 断点 tcp_alloc 的会话现场（文本见正文）
