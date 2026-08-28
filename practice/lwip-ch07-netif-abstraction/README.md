# lwIP 深度解析（七）实验：netif 抽象层契约

基于第三章 openeth 联网模板（esp_netif + esp_eth + openeth MAC，QEMU SLIRP 网络）。

## 实验

- **E1 netif 解剖**：`tcpip_callback` 里遍历 `netif_list`，打印 `lo` 与 `en` 两张网卡的全部契约字段
  （ip 三元组、mtu、flags 解码、hwaddr、input/output/linkoutput 函数指针、state 背指针、DHCP client_data 槽位）。
- **E2 路由分派**：tcpip 线程内直接调 `ip4_route()` 对 127.0.0.1 / 10.0.2.2 / 10.0.2.3 / 192.168.199.99
  做分派探测；再用 esp_ping 做 10.0.2.2 与 127.0.0.1 的行为交叉验证。
- **E3 故障注入**：`netif_set_link_down(en)` 后观察 UDP 发送失败（errno）、ping 全灭、路由表塌缩；
  `netif_set_link_up(en)` 观察恢复与 DHCP reboot（`LWIP_NSC_IPV4_ADDR_VALID` 单独再现，无重新 discover）。

全程用自注册的 netif ext-callback 记录 `LWIP_NSC_*` 事件流。

## 运行

```bash
. ~/esp/esp-idf/export.sh
idf.py set-target esp32     # 仅首次
idf.py build
idf.py qemu monitor < /dev/null || true   # 生成 build/qemu_flash.bin 与 qemu_efuse.bin
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 50 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot 2>&1 | tee run.log
```

`sdkconfig.defaults`：openeth 使能 + `CONFIG_LWIP_STATS=y`（读协议计数器）。
