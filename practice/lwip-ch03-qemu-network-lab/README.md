# lwip-ch03-qemu-network-lab

《lwIP 深度解析（三）》实验工程：QEMU OpenCores 网卡（openeth）+ SLIRP 用户态网络的第一包。

**本工程 `main/lab_main.c` 的以太网 bring-up 序列是系列后续所有联网章节的标准模板。**

内容：

1. openeth bring-up：`esp_netif_init` → event loop → `esp_netif_new(ESP_NETIF_DEFAULT_ETH())`
   → `esp_eth_mac_new_openeth` + `esp_eth_phy_new_generic` → `esp_eth_driver_install`
   → `esp_eth_new_netif_glue` + `esp_netif_attach` → 事件注册 → `esp_eth_start` → 等 DHCP。
2. 实验 A：DHCP 拿到 10.0.2.15 后，用 lwIP 内置 ping 应用组件
   （`components/lwip/include/apps/ping/ping_sock.h`）ping SLIRP 网关 10.0.2.2。
3. 实验 B：最小 TCP echo server（socket API，端口 8888），配合
   `-nic user,model=open_eth,hostfwd=tcp::8003-:8888` 供主机 `nc localhost 8003` 验证。
4. 实验 C：SLIRP DNS 行为探针（转发上游 / 查宿主机 /etc/hosts / 失败路径）。

构建与运行见仓库 `practice/lwip-labs/CONVENTIONS.md` 第 3 节；实验输出在 `run.log`、
`echo_run.log`、`echo_client.out`。
