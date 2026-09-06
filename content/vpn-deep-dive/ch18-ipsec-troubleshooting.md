---
title: "VPN 技术深度探索 (十八)：IPSec 排错实战"
date: 2026-04-13
tags:
  [
    vpn,
    series,
    networking,
    security,
    ipsec,
    troubleshooting,
    strongswan,
    charon,
    nat-traversal,
    debug,
    tcpdump,
    ike-debug,
  ]
description: "IPSec 排错实战——strongSwan/Charon 日志分析、IKE 协商失败定位、NAT 穿透问题排查、ESP 解密失败处理、防重放告警分析、MTU 分片问题、常见错误码速查、系统性排错方法论"
---

> [!info] VPN 技术深度探索系列 14. [[ch14-ipsec-overview|IPSec 体系概述]] 15. [[ch15-ipsec-ike|IKE 密钥交换]] 16. [[ch16-ipsec-esp|AH 与 ESP 协议]] 17. [[ch17-ipsec-policy|IPSec 策略配置]]
> **18. IPSec 排错（本章）**

---

## 1. IPSec 排错方法论

### 1.1 分层排错思路

IPSec 问题通常可归类到三层：

```
Layer 1：网络连通性
  对等体之间 UDP 500/4500 是否可达？
  防火墙是否放行 ESP（IP 50）和 AH（IP 51）？

Layer 2：IKE 协商层
  IKE SA 能否建立？（Phase 1 / IKE_SA_INIT）
  IPSec SA 能否建立？（Phase 2 / IKE_AUTH / CREATE_CHILD_SA）
  算法是否匹配？认证是否通过？

Layer 3：数据平面
  SA 已建立，但数据不通？
  SPD 策略是否正确匹配流量？
  MTU/分片是否导致丢包？
  防重放窗口是否误丢包？
```

### 1.2 排错工具清单

```
工具                用途
─────────────────────────────────────────────────────
swanctl             查询 strongSwan 连接/SA 状态
ip xfrm             查看/修改内核 SA 和策略
tcpdump             抓取 IKE 和 ESP 报文
wireshark           解析 IKE 协议（可配合密钥解密）
journalctl          strongSwan charon 日志
/proc/net/xfrm_stat 内核 xfrm 统计（丢包计数）
ike-scan            扫描对端 IKE 端口，枚举 Transform
ping/traceroute     基础连通性测试
iptables -nvL       检查防火墙规则
ss / netstat        查看 UDP 500/4500 监听
```

---

## 2. strongSwan 日志调试

### 2.1 日志子系统详解

strongSwan charon 日志分为多个子系统，可独立调整级别（-1～4）：

```
子系统      说明
────────────────────────────────────────────────
ike         IKE SA 协商主流程
chd         Child SA（IPSec SA）管理
cfg         配置加载/解析
knl         内核接口（xfrm state/policy 操作）
net         网络 I/O（IKE 报文收发）
enc         IKE 报文编解码
lib         基础库
tls         EAP-TLS 子系统
esp         ESP 数据包处理（不常用）
```

日志级别：

- **-1**：不输出
- **0**：只输出错误
- **1**：警告（默认）
- **2**：信息
- **3**：调试
- **4**：详细调试（含 hex dump）

### 2.2 调整日志级别

**/etc/strongswan.d/charon-logging.conf**：

```
charon {
  filelog {
    /var/log/charon.log {
      time_format = %Y-%m-%d %T
      append = no
      flush_line = yes
      default = 1         # 默认级别
      ike = 3             # IKE 协商详细
      chd = 3             # Child SA 详细
      cfg = 2
      knl = 2             # 内核操作
      net = 2
      enc = 1
    }
  }
  syslog {
    daemon {
      default = 1
    }
  }
}
```

临时提升日志级别（不重启）：

```bash
# strongSwan 5.x swanctl
swanctl --log --level ike:3 --level chd:3

# 或发送 SIGUSR1 信号给 charon（旧版本）
kill -USR1 $(pidof charon)
```

### 2.3 实时查看日志

```bash
# 查看 charon 日志（journald）
journalctl -u strongswan -f

# 查看日志文件
tail -f /var/log/charon.log

# 过滤特定 IP
journalctl -u strongswan | grep "192.168.2.1"
```

---

## 3. IKE 协商失败排查

### 3.1 IKE_SA_INIT 失败

**症状**：连接后无 SA，日志出现错误。

**常见原因与日志特征**：

```
错误 1：UDP 500 不可达
  症状：无响应，多次重传后超时
  日志：retransmit 1 of request... retransmit 2...
        giving up after 5 tries, dropping...

  排查：
    tcpdump -i eth0 'udp port 500 or udp port 4500'
    # 检查对端是否有 UDP 500 的回包
    nc -u -z 192.168.2.1 500

错误 2：算法套件不匹配（NO_PROPOSAL_CHOSEN）
  症状：协商失败，对端返回 NO_PROPOSAL_CHOSEN
  日志：received NO_PROPOSAL_CHOSEN notify
        no proposal found

  排查：
    # GW-A 提议的算法套件
    swanctl --list-conns
    # 对端（GW-B）接受的套件是否有交集？

  解决：确保双端 proposals / esp_proposals 有共同算法
    proposals = aes256gcm128-prfsha256-ecp256,aes128gcm128-prfsha256-ecp256
    # 添加更多备选，或与对端协商统一算法

错误 3：防火墙拦截
  症状：有发包无回包
  排查：
    iptables -nvL INPUT | grep -E '500|4500|esp|ah'
    # 确保放行：
    iptables -A INPUT  -p udp --dport 500  -j ACCEPT
    iptables -A INPUT  -p udp --dport 4500 -j ACCEPT
    iptables -A INPUT  -p 50               -j ACCEPT  # ESP
    iptables -A INPUT  -p 51               -j ACCEPT  # AH
    iptables -A OUTPUT -p udp --sport 500  -j ACCEPT
    iptables -A OUTPUT -p udp --sport 4500 -j ACCEPT
    iptables -A OUTPUT -p 50               -j ACCEPT
    iptables -A FORWARD -p 50              -j ACCEPT  # 若为网关
```

### 3.2 IKE_AUTH 失败（认证失败）

```
错误 1：PSK 不匹配（AUTHENTICATION_FAILED）
  日志：authentication of '...' with pre-shared key failed
        received AUTHENTICATION_FAILED notify error

  排查：
    # 双端 PSK 是否完全一致（注意大小写、空格、特殊字符）
    # 检查 IKE 身份 ID 是否匹配（id 配置）
    swanctl --list-conns | grep id

  解决：重新核对双端 secrets 配置

错误 2：证书验证失败
  日志：certificate verification failed
        issuer cert not found for...
        certificate is not trusted

  排查：
    # 检查证书链
    openssl verify -CAfile ca.pem server-cert.pem

    # 检查证书有效期
    openssl x509 -in server-cert.pem -noout -dates

    # 检查 SAN（Subject Alternative Name）是否包含对端 IP/域名
    openssl x509 -in server-cert.pem -noout -text | grep -A5 "Subject Alternative"

  解决：
    - 更新过期证书
    - 确保 CA 证书在双端 cacerts 目录中
    - SAN 包含对端使用的 ID（IP 或域名）

错误 3：身份 ID 不匹配
  日志：IKE_SA (...)  match for peer... failed, found no matching config

  排查：
    # 检查 remote.id 配置与对端发送的 IDr 是否一致
    # 开启 enc 和 ike 日志级别 3 查看 ID 内容
```

### 3.3 Child SA 建立失败（IPSec SA）

```
错误：流量选择符不匹配（TS_UNACCEPTABLE）
  日志：TS_UNACCEPTABLE received, no acceptable TS found
        traffic selectors 10.0.3.0/24/0/65535 not acceptable

  排查：
    # 检查双端 local_ts / remote_ts 配置
    # GW-A 的 local_ts 应等于 GW-B 的 remote_ts

  解决：修正流量选择符配置，确保双端互补

错误：IPSec SA 算法不匹配
  日志：no acceptable proposal found

  解决：检查 esp_proposals 配置，确保双端有共同支持的 ESP 算法
```

---

## 4. NAT 穿透问题排查

### 4.1 诊断 NAT 是否存在

```bash
# 开启 net 日志级别 2
# 观察 NAT-T 检测日志：

# 有 NAT 的情况：
# local host is behind NAT, NAT_DETECTION_SOURCE_IP notify
# remote host is behind NAT, NAT_DETECTION_DESTINATION_IP notify

# 无 NAT：
# no NAT detected, not enabling NAT-T

# 检查 IKE 是否切换到 4500 端口
tcpdump -i eth0 'udp port 4500' -nn
```

### 4.2 NAT-T ESP 封装问题

```
问题 1：路径上有设备阻断 UDP 4500
  症状：IKE 在 4500 建立成功，但 ESP 数据不通
  排查：
    tcpdump -i eth0 'udp port 4500' -nn
    # 查看 ESP-in-UDP 报文是否有来回

  解决：确保路径上所有防火墙放行 UDP 4500

问题 2：NAT 设备超时删除 UDP 映射
  症状：VPN 空闲一段时间后断连
  解决：
    # strongSwan 调整 keepalive 间隔（默认 20 秒）
    # /etc/strongswan.d/charon.conf：
    charon {
      keep_alive = 20    # NAT-T keepalive 间隔（秒）
    }

问题 3：多个 VPN 客户端在同一 NAT 后面
  症状：第二个客户端无法建立 VPN（或覆盖第一个）
  原因：IKEv1 无法区分同一 NAT IP 后面的多个客户端
  解决：使用 IKEv2（支持通过随机 SPIi/SPIr 区分客户端）
```

### 4.3 同时检查 iptables NAT 规则

```bash
# 查看 MASQUERADE 规则（可能对 ESP 包做 SNAT）
iptables -t nat -nvL POSTROUTING

# IPSec 出站流量不应被 MASQUERADE（否则影响 IKE）
# 添加排除规则：
iptables -t nat -I POSTROUTING -o eth0 \
    -m policy --pol ipsec --dir out \
    -j ACCEPT    # 跳过 MASQUERADE
```

---

## 5. 数据平面排查

### 5.1 SA 已建立但数据不通

```bash
# Step 1：确认 SA 已建立且有流量计数
swanctl --list-sas
# 查看 bytes-in / bytes-out 是否在增长

ip xfrm state
# 查看 stats 字段：replay-window N replay M failed K

# Step 2：确认 SPD 策略存在且正确
ip xfrm policy
# 检查 src/dst 子网和方向（in/out/fwd）是否匹配实际流量

# Step 3：检查路由是否正确（路由 VPN）
ip route get 10.0.2.1
# 应该走 xfrm0/vti0 接口

# Step 4：抓包验证
# 在 VPN 接口前抓包（内层）
tcpdump -i eth0.internal -nn 'host 10.0.2.1'
# 在 WAN 接口抓包（外层 ESP）
tcpdump -i eth0 -nn 'esp or (udp port 4500)'
```

### 5.2 xfrm 统计分析

```bash
cat /proc/net/xfrm_stat

关键计数器解释：
XfrmInError           总入站错误（各类错误之和）
XfrmInBufferError     内存分配失败
XfrmInHdrError        IP 头错误
XfrmInNoStates        找不到 SA（SPI 不匹配）← SA 未建立或对端重启
XfrmInStateProtoError 协议不匹配（AH/ESP 混淆）
XfrmInStateModeError  模式不匹配（传输/隧道混淆）
XfrmInStateSeqError   序列号/防重放错误 ← 重排序或重放攻击
XfrmInStateExpired    SA 已过期（需要 Rekey）
XfrmInStateMismatch   SA 参数不匹配
XfrmInStateInvalid    SA 状态无效
XfrmInTmplMismatch    SPD 模板不匹配 ← 策略配置错误
XfrmInNoPols          无匹配的 SPD 策略
XfrmInPolBlock        策略 DISCARD
XfrmInPolError        策略错误
XfrmOutError          总出站错误
XfrmOutBundleCheckError  Bundle 完整性错误
XfrmOutBundleGenerateError  Bundle 生成错误
XfrmOutNoStates       无 SA → 触发 IKE 协商
XfrmOutStateProtoError  出站协议错误
XfrmOutStateModeError   出站模式错误
XfrmOutStateSeqError    出站序列号错误
XfrmOutStateExpired     出站 SA 过期
XfrmOutPolBlock         出站策略 DISCARD
XfrmOutPolDead          策略中的 SA 已死亡
XfrmOutPolError         出站策略错误
```

常见问题对应的计数器：

```
SA 未建立：XfrmInNoStates / XfrmOutNoStates 持续增长
防重放误丢：XfrmInStateSeqError 增长（检查网络重排序）
策略不匹配：XfrmInNoPols / XfrmInTmplMismatch 增长
SA 过期：XfrmInStateExpired 增长（检查 Rekey 是否正常工作）
```

---

## 6. MTU 与分片问题

### 6.1 IPSec 隧道开销

```
IPv4 + ESP（AES-GCM）+ NAT-T 隧道模式：
  外层 IPv4 头：20 字节
  UDP（NAT-T）：8 字节
  ESP 头：      8 字节（SPI + Seq）
  IV（GCM）：   8 字节
  ESP 尾：      约 2-4 字节
  ICV（GCM）：  16 字节
  ─────────────────────────
  总开销：      约 62-66 字节

若链路 MTU = 1500：
  最大内层载荷（含内层 IP 头 20B）= 1500 - 66 = 1434 字节
  内层有效载荷（TCP/UDP）        = 1434 - 20 = 1414 字节

建议：设置 VPN 接口 MTU = 1400（留足余量）
```

### 6.2 MTU 问题诊断

```bash
# 测试不同大小报文是否通过 VPN
ping -M do -s 1400 10.0.2.1    # 不分片，1400 字节载荷
ping -M do -s 1350 10.0.2.1    # 较小尺寸

# 若大包丢失，小包正常 → MTU 问题

# 查看接口 MTU
ip link show xfrm0
ip link show vti0

# 设置接口 MTU
ip link set xfrm0 mtu 1400

# 启用 TCP MSS Clamp（自动修正 TCP SYN 的 MSS 值）
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
    -o xfrm0 \
    -j TCPMSS --clamp-mss-to-pmtu
```

### 6.3 PMTUD（路径 MTU 发现）

```bash
# 确保 ICMP fragmentation needed 报文不被防火墙丢弃
iptables -A INPUT  -p icmp --icmp-type fragmentation-needed -j ACCEPT
iptables -A OUTPUT -p icmp --icmp-type fragmentation-needed -j ACCEPT
iptables -A FORWARD -p icmp --icmp-type fragmentation-needed -j ACCEPT

# 查看是否收到 ICMP 分片需要消息
tcpdump -i eth0 'icmp and (icmp[0] = 3 and icmp[1] = 4)'
```

---

## 7. 防重放告警处理

### 7.1 XfrmInStateSeqError 持续增长

**原因分析**：

```
可能原因 1：网络乱序
  高速/多路径网络中，包可能乱序到达
  防重放窗口默认 64 包，乱序超过窗口大小 → 误丢

  解决：扩大防重放窗口
    ip xfrm state add ... replay-window 128

    strongSwan 配置（/etc/strongswan.d/charon.conf）：
      replay_window = 128

可能原因 2：真实重放攻击
  检查是否有来自可疑 IP 的重放包
  tcpdump -i eth0 'esp' -nn | 分析 SPI 和源 IP

可能原因 3：SA 重协商期间包乱序
  旧 SA 的最后几包与新 SA 的头几包可能乱序
  属于正常现象，短暂出现不需处理
```

### 7.2 序列号回绕

```
当 SA 序列号接近 2^32 时，必须 Rekey：

观察方法：
  watch -n 1 'ip xfrm state | grep -A3 "seq"'

若序列号增长过快（高速链路）：
  使用 ESN（扩展序列号，64位）
  strongSwan 配置：
    esp_proposals = aes256gcm128-esn-ecp256
    # esn = Extended Sequence Number
```

---

## 8. 完整排错案例

### 案例一：IKE 协商成功但无数据流量

```
症状：swanctl --list-sas 显示 SA ESTABLISHED，
      但 ping 10.0.2.1 不通

Step 1：检查 xfrm 统计
  cat /proc/net/xfrm_stat | grep -E 'NoPols|TmplMismatch|NoStates'
  → XfrmOutNoStates 持续增长

Step 2：检查 SPD 策略
  ip xfrm policy
  → 策略 src/dst 子网写反了（local/remote_ts 配置错误）

修复：交换 local_ts 和 remote_ts 配置，重新连接
```

### 案例二：VPN 建立后几分钟断连

```
症状：VPN 每隔几分钟自动断开并重连，swanctl 日志：
  deleting IKE_SA ... due to inactivity

Step 1：检查 DPD 配置
  swanctl --list-conns | grep dpd

Step 2：检查网络中是否有 UDP 4500 超时丢弃
  tcpdump -i eth0 'udp port 4500' | 查看 NAT-T keepalive 是否有回包

Step 3：检查 dpd_delay 设置（可能太短）

修复：
  dpd_delay = 30s
  dpd_timeout = 90s
  keep_alive = 20  # NAT-T keepalive

  确保路径中 NAT 设备 UDP 超时 > keep_alive 间隔
```

### 案例三：大包通过 VPN 失败

```
症状：SSH/Ping 正常，HTTP 大文件传输卡住/超时

Step 1：使用不同大小 ping 测试
  ping -M do -s 1400 10.0.2.1  → 成功
  ping -M do -s 1450 10.0.2.1  → 失败

Step 2：确认是 MTU 问题
  tcpdump -i eth0 'icmp' → 是否有 frag needed 回包？
  → 无 ICMP frag needed：路径上有防火墙丢弃 ICMP

Step 3：强制 MSS Clamp
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --set-mss 1360

  降低 VPN 接口 MTU：
  ip link set xfrm0 mtu 1380
```

### 案例四：证书过期导致每天断连

```
症状：每天同一时刻 VPN 断连，日志出现证书错误

检查证书有效期：
  openssl x509 -in /etc/swanctl/x509/server.pem -noout -enddate
  → notAfter=Apr 13 10:00:00 2026 GMT （已过期！）

解决：
  1. 更新证书（从 CA 重新签发）
  2. 设置证书到期前告警：
     # 脚本检查证书有效期
     days=$(( ($(openssl x509 -in server.pem -noout -enddate \
         | cut -d= -f2 | date -f- +%s) - $(date +%s)) / 86400 ))
     [ $days -lt 30 ] && echo "证书将在 ${days} 天后过期！"

  3. 使用 certbot 或 ACME 自动续期
```

---

## 9. strongSwan 常用调试命令速查

```bash
# ── 状态查询 ──────────────────────────────────────
swanctl --list-sas           # 查看已建立的 IKE/Child SA
swanctl --list-conns         # 查看配置的连接
swanctl --list-certs         # 查看已加载的证书
swanctl --stats              # 查看守护进程统计

# ── 连接控制 ──────────────────────────────────────
swanctl --initiate --child <name>  # 手动触发建立
swanctl --terminate --ike <name>   # 手动断开 IKE SA
swanctl --rekey --ike <name>       # 手动触发重协商
swanctl --redirect --ike <id> --peer-ip <ip>  # 重定向客户端

# ── 配置重载 ──────────────────────────────────────
swanctl --load-all           # 加载所有配置（连接+证书+密钥）
swanctl --load-creds         # 仅加载证书和密钥

# ── 实时日志 ──────────────────────────────────────
swanctl --log                # 实时日志流

# ── 内核 xfrm ─────────────────────────────────────
ip xfrm state flush          # 清空所有 SA（会断连！）
ip xfrm policy flush         # 清空所有策略
ip xfrm state count          # SA 数量统计
ip xfrm monitor              # 实时监控 SA/策略变化

# ── 抓包 ──────────────────────────────────────────
# 抓 IKE 包（UDP 500/4500）
tcpdump -i eth0 -nn -w ike.pcap '(udp port 500 or udp port 4500)'
# 抓 ESP 包
tcpdump -i eth0 -nn -w esp.pcap 'proto 50'
# 抓内层解密后的流量（在 VPN 虚拟接口上）
tcpdump -i xfrm0 -nn
```

---

## 10. 常见错误码速查

| 错误 / Notify         | 含义                | 常见原因                       |
| --------------------- | ------------------- | ------------------------------ |
| NO_PROPOSAL_CHOSEN    | 算法提议无交集      | 双端 proposals 配置不匹配      |
| AUTHENTICATION_FAILED | 认证失败            | PSK 不一致、证书问题           |
| TS_UNACCEPTABLE       | 流量选择符不接受    | local_ts/remote_ts 配置错误    |
| INVALID_KE_PAYLOAD    | DH 组不接受         | DH 组不在对端接受列表          |
| INVALID_SYNTAX        | 报文语法错误        | 实现 Bug 或版本不兼容          |
| CHILD_SA_NOT_FOUND    | 找不到 Child SA     | SA 已删除或 SPI 错误           |
| TEMPORARY_FAILURE     | 临时失败            | 资源不足，稍后重试             |
| SINGLE_PAIR_REQUIRED  | 需要单一选择符对    | 某些实现限制                   |
| FAILED_CP_REQUIRED    | 需要 CP（配置载荷） | 客户端需要 IP 分配但服务端未配 |
| INVALID_MAJOR_VERSION | IKE 版本不支持      | 强制 IKEv2 但对端只支持 v1     |

---

## 11. 本章小结

```
IPSec 排错核心思路：

1. 确认网络可达：
   UDP 500/4500 双向可达？
   防火墙放行 ESP(50)、AH(51)、UDP 500/4500？

2. IKE 协商层排查：
   日志级别提升：ike=3, chd=3, net=2, knl=2
   查看错误 Notify 类型（对照错误码速查表）
   算法 / PSK / 证书 / ID 哪里不匹配？

3. 数据平面排查：
   ip xfrm state  → SA 是否存在，流量计数是否增长
   ip xfrm policy → SPD 策略方向/子网是否正确
   /proc/net/xfrm_stat → 哪类错误在增长？

4. 常见问题：
   MTU：大包丢失 → MSS Clamp + 降低接口 MTU
   NAT-T：UDP 4500 被拦 / NAT 超时 → keepalive + 放行规则
   防重放误丢：replay-window 扩大
   证书过期：定期检查 + 自动续期

5. 终极手段：tcpdump 抓包
   对端有没有收到我们的 IKE 包？
   有没有返回错误 Notify？
   ESP 包有没有到达目的地？
```

---

## 参考资料

- strongSwan Log Analysis: https://docs.strongswan.org/docs/5.9/support/log-analysis.html
- RFC 7296 Section 3.11: IKEv2 Notify Message Types
- iproute2 ip-xfrm(8) Manual
- Linux xfrm_stat: Documentation/networking/xfrm_proc.rst
- Wireshark IKEv2 Dissector: Edit → Preferences → IKEv2 → Pre-Shared Keys
- strongSwan Troubleshooting Wiki: https://wiki.strongswan.org/projects/strongswan/wiki/CorrectConfiguration
