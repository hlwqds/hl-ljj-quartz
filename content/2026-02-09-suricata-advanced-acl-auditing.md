---
title: Suricata 高级 ACL 与流量审计实战指南（进阶版）
date: 2026-02-09 08:00:00
pin: true
tags: [Network, Suricata, ACL, Compliance, Traffic Analysis]
---


本文档旨在提供一套完整的 Suricata 流量审计解决方案，涵盖从**配置文件修改**、**规则编写语法**到**日志输出分析**的全链路知识。特别针对协议合规性、国密检测及握手状态审计进行了深度解析。

---

## 第一章：基础配置与环境准备

在编写任何 ACL 规则之前，必须确保 Suricata 的配置能够支持高级日志记录和自定义分类。

### 1.1 注册自定义分类 (Classification)
Suricata 不允许在规则中使用未定义的 `classtype`。你必须先在配置文件中注册。

*   **配置文件路径**：通常位于 `/etc/suricata/classification.config`。
*   **配置语法**：
    `config classification: <短名称>, <描述文本>, <默认优先级>`
    *   **短名称**：在规则中引用的 ID（如 `non-compliant-crypto`）。
    *   **描述文本**：在日志 `category` 字段中显示的内容。
    *   **优先级**：1 (最高/High) ~ 4 (最低/Low)。

**【实战操作】** 请将以下内容追加到 `classification.config` 文件末尾：

```config
# --- Custom ACL Classifications ---
# 1. 未知或无法识别的协议 (关注度: 低)
config classification: unknown-protocol, Unrecognized Application Protocol, 3

# 2. 禁止使用的协议 (关注度: 高)
config classification: forbidden-protocol, Forbidden Protocol Policy Violation, 1

# 3. 非标准端口使用 (关注度: 中)
config classification: non-standard-port, Protocol on Non-Standard Port, 2

# 4. 加密合规性问题 (非国密/弱加密) (关注度: 中)
config classification: non-compliant-crypto, Non-Compliant/Weak Cryptography, 2

# 5. 协议异常与握手失败 (关注度: 中)
config classification: protocol-anomaly, Application Protocol Anomaly, 2
```

### 1.2 开启高级日志记录
为了在日志中看到 `metadata` 标签和详细的 TLS 信息，需修改 `suricata.yaml`。

**【实战操作】** 确保 `outputs.eve-log` 部分配置如下：

```yaml
outputs:
  - eve-log:
      enabled: yes
      types:
        - alert:
            payload: yes           # (可选) 记录攻击包的载荷
            metadata: yes          # 【关键】必须开启，否则规则里的 metadata 不显示
            tagged-packets: yes    # 开启后可记录 tag 关键字标记的后续数据包
        - tls:
            extended: yes          # 【关键】开启扩展字段，记录握手状态、证书链等
            custom: [subject, issuer, serial, fingerprint, sni, version, cipher, ja3]
```

---

## 第二章：五大类审计规则详解

以下规则基于上述注册的 `classtype` 编写。

### 场景一：未能识别的协议 (Unknown Protocol)
*   **原理**：利用 `app-layer-event` 事件。当 Suricata 尝试解析流量但失败，或流量没有任何已知的协议特征时触发。
*   **难点**：直接检测“未知”很难，通常是检测“解析失败”。

```suricata
# 检测应用层协议探测失败（可能意味着使用了私有加密协议或未注册协议）
alert ip $HOME_NET any -> any any (msg:"AUDIT: Application Layer Detection Failed"; flow:established; app-layer-event:applayer_detection_failed; classtype:unknown-protocol; sid:3000001; rev:1;)

# 检测解析过程中出错（特征匹配了但格式不对）
alert ip $HOME_NET any -> any any (msg:"AUDIT: Application Layer Parse Error"; flow:established; app-layer-event:applayer_parse_error; classtype:unknown-protocol; sid:3000002; rev:1;)
```

### 场景二：识别出特定禁用协议 (Forbidden Protocol)
*   **原理**：利用 Suricata 强大的协议识别能力，不依赖端口，只看协议特征。

```suricata
# 禁止内网使用 Telnet (明文传输)
alert telnet $HOME_NET any -> any any (msg:"POLICY: Forbidden Telnet Protocol Detected"; flow:established; classtype:forbidden-protocol; sid:3000010; rev:1;)

# 禁止使用 VNC 远程桌面
alert vnc $HOME_NET any -> any any (msg:"POLICY: Forbidden VNC Protocol Detected"; flow:established; classtype:forbidden-protocol; sid:3000011; rev:1;)

# 禁止 BitTorrent 流量
alert bittorrent $HOME_NET any -> any any (msg:"POLICY: P2P BitTorrent Traffic"; flow:established; classtype:forbidden-protocol; sid:3000012; rev:1;)
```

### 场景三：非标端口协议 (Non-standard Port)
*   **原理**：`alert <协议> ... -> ... <端口逻辑>`。
*   **逻辑**：如果识别出是 HTTP 协议，但目标端口不是 80, 8080, 8000，则告警。

```suricata
# 发现 HTTP 跑在非标准端口（排除常用端口）
alert http any any -> any ![80,8080,8000,8008] (msg:"AUDIT: HTTP on Non-Standard Port"; flow:established; classtype:non-standard-port; sid:3000020; rev:1;)

# 发现 TLS/HTTPS 跑在非 443 端口（可能是为了绕过防火墙）
alert tls any any -> any !443 (msg:"AUDIT: TLS on Non-Standard Port"; flow:established; classtype:non-standard-port; sid:3000021; rev:1;)

# 发现 SSH 跑在非 22 端口
alert ssh any any -> any !22 (msg:"AUDIT: SSH on Non-Standard Port"; flow:established; classtype:non-standard-port; sid:3000022; rev:1;)
```

### 场景四：非国密流量与弱加密 (Non-Compliant Crypto)
*   **原理**：通过 `tls.cipher` 关键字匹配加密套件名称。
*   **国密特征**：通常包含字符串 "SM4" 或以 "GMSL" 开头（如 `GMSL_ECDHE_SM4_CBC_SM3`）。
*   **逻辑非 (!)**：如果不包含 SM4 且不包含 GMSL，则视为非国密。

```suricata
# 【核心规则】检测 TLS 流量中未使用国密算法
# 逻辑：是 TLS 协议 AND (套件名不含 SM4) AND (套件名不含 GMSL)
alert tls any any -> any any (msg:"COMPLIANCE: Non-SM (International) Cipher Suite Detected"; flow:established; tls.cipher:!"SM4"; tls.cipher:!"GMSL"; classtype:non-compliant-crypto; metadata:tag compliance, tag non_sm; sid:3000030; rev:1;)

# 检测使用了过时的 TLS 版本 (TLS 1.0 / 1.1)
alert tls any any -> any any (msg:"COMPLIANCE: Obsolete TLS Version (1.0/1.1)"; flow:established; tls.version:[1.0, 1.1]; classtype:non-compliant-crypto; sid:3000031; rev:1;)

# 检测弱加密算法 (DES/RC4/MD5)
alert tls any any -> any any (msg:"SECURITY: Weak Cipher Suite (DES/RC4/MD5)"; flow:established; tls.cipher:/DES|RC4|MD5/; classtype:non-compliant-crypto; sid:3000032; rev:1;)
```

### 场景五：协议解析异常与握手未完成 (Protocol Anomaly)
*   **原理**：握手未完成通常表现为连接在交换数据前断开，或协议交互顺序错误。
*   **检测点**：主要依赖 `app-layer-event`。

```suricata
# TLS 握手失败/未完成 (Client Hello 发了但没走到 Handshake Done)
alert tls any any -> any any (msg:"ANOMALY: TLS Handshake Failed/Incomplete"; app-layer-event:applayer_detection_failed; classtype:protocol-anomaly; sid:3000040; rev:1;)

# 检测到 TLS 服务器发送了致命错误警报 (Fatal Alert)
# 这意味着服务器拒绝了连接（可能是证书错误、版本不支持等）
alert tls any any -> any any (msg:"ANOMALY: TLS Fatal Alert from Server"; app-layer-event:tls.handshake_failure; classtype:protocol-anomaly; sid:3000041; rev:1;)
```

---

## 第三章：Tag 与 Metadata 深度指南

### 3.1 Metadata：结构化标签
Suricata 的 `metadata` 是为了给日志增加上下文，而不是为了改变检测逻辑。

*   **语法**：`metadata: key value, key value;`
*   **模拟 Tag 列表**：为了让日志更像 Tags 列表，建议统一使用 `tag` 作为 Key。

**示例规则：**
```suricata
alert http any any -> any any (msg:"Test Rule"; metadata: tag production, tag dmz, owner security_team; sid:1; rev:1;)
```

**对应的 JSON 输出：**
```json
"alert": {
  "metadata": {
    "tag": ["production", "dmz"],
    "owner": ["security_team"]
  }
}
```

### 3.2 关键字 `tag` (功能性标记)
不要混淆 `metadata` 和 `tag` 关键字。
*   `tag: session, 600, seconds;` -> 这是一个**动作**。
*   **作用**：一旦规则命中，Suricata 会在后续 600 秒内记录该会话的**所有**数据包（即使没有触发其他告警）。这对于事后取证非常有用。

---

## 第四章：JSON 日志字段映射参考

理解规则如何映射到日志，对于配置 SIEM (ELK/Splunk) 至关重要。

| 规则关键字 | JSON 字段位置 (`eve.json`) | 说明 |
| :--- | :--- | :--- |
| `msg:"..."` | `alert.signature` | 告警名称 |
| `classtype:name` | `alert.category` | 输出的是分类的**描述文本** |
| `classtype:name` | `alert.severity` | 对应的优先级数字 |
| `metadata: k v` | `alert.metadata.{k}` | 值为数组格式 |
| `sid:123` | `alert.signature_id` | 规则 ID |
| `app-layer-protocol` | `app_proto` | 识别出的协议 (如 `http`, `tls`) |
| (TLS 引擎) | `tls.version` | 实际使用的版本 |
| (TLS 引擎) | `tls.cipher` | 实际使用的加密套件 |
| (TLS 引擎) | `tls.handshake_done` | 布尔值 `true`/`false` |

---

## 第五章：常见问题排查 (Troubleshooting)

### Q1: 为什么我的 classtype 报错 "Unknown classtype"？
*   **原因**：你可能只在规则里写了 `classtype`，但没有在 `classification.config` 文件里注册它。
*   **解决**：编辑配置文件，添加定义，然后重启 Suricata。

### Q2: 为什么 "非国密" 规则 (tls.cipher:!"SM4") 产生了大量误报？
*   **原因**：互联网上绝大多数流量（如访问 Google, Baidu）都是非国密的。
*   **解决**：
    1.  限制源/目的 IP：只检测内网服务器 (`$HOME_NET`) 对外提供的服务。
    2.  `alert tls $HOME_NET any -> $EXTERNAL_NET any ...`

### Q3: `metadata` 在日志里没显示？
*   **原因**：`suricata.yaml` 中 `outputs.eve-log.types.alert.metadata` 默认为 `no` 或被注释掉了。
*   **解决**：设置为 `yes` 并重载配置。

### Q4: 如何不重启 Suricata 更新规则？
*   **命令**：`suricatasc -c ruleset-reload_rules`
*   或者发送信号：`kill -USR2 $(pidof suricata)`
*   *注意：修改 classification.config 通常需要完全重启进程。*

---
*文档生成时间：2026-02-05*
