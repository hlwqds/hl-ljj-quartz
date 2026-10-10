# ch07-minivpn —— TUN × 安全信封的双端 mini-VPN

[[ch07-minivpn|第七章：组装 mini-VPN]] 的总装实现：TUN 读写（ch03）、ChaCha20 +
HMAC-SHA256 安全信封与滑动窗口（ch04/ch05 零件复用）、双向计数器、10s keepalive、
`--hexdump`（TUN 观察器）、`--loopback`（自环自检，无需 root）、recvfrom 顺带刷新
peer 地址（roaming 思想）。**Linux 真机工程**：本仓以 `zig cc -target x86_64-linux`
交叉编译验证入库，运行输出待真机回填（诚实性规则见套件 SPEC §2）。

## 拓扑

```text
A 机: 应用 → tun0(10.7.0.1) → minivpn seal → UDP:51820 ═══▶ B 机
B 机: UDP:51820 → unseal（验章/查窗/解密） → write(tun0 10.7.0.2) → 应用
密钥文件 64B = [加密钥 32B][MAC 钥 32B]；--role a/b 互异 → nonce 方向隔离
```

## 编译（Linux 本机，或任意平台交叉验证）

```bash
zig cc -target x86_64-linux -O2 -o minivpn minivpn.c chacha20.c sha256.c hmac.c
# 本机 gcc：cc -O2 -o minivpn minivpn.c chacha20.c sha256.c hmac.c
```

## 真机实验（两台 Linux，详见正文 ch07/ch08）

```bash
./minivpn --loopback                                    # ① 自环自检（无需 root）
head -c 64 /dev/urandom > vpn.key && scp vpn.key B:     # ② 密钥分发（ch06 的教训现场）
A# ./minivpn --tun tun0 --key vpn.key --role a --peer B公网:51820 &
B# ./minivpn --tun tun0 --key vpn.key --role b --peer A公网:51820 &
A# ip addr add 10.7.0.1/24 dev tun0 && ip link set tun0 up mtu 1420
B# ip addr add 10.7.0.2/24 dev tun0 && ip link set tun0 up mtu 1420
A# ping 10.7.0.2                                        # ③ 隧道验收
A# ./minivpn --hexdump …                                # ④ 观察进 TUN 的 IP 包
# ⑤ 全隧道/转发的系统侧命令清单见 [[ch08-routing|第八章]]（两段式路由、
#    ip_forward、MASQUERADE、DNS、MSS 钳制——wg-quick 的本质）
```

静态密钥的三笔债（无前向保密/手工分发/无认证）与还债方向见 [[ch09-wireguard-contrast|
第九章]] 对照表。完整验证记录见 `run.log`。
