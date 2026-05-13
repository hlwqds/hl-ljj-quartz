---
title: "Zeek 深度探索 (十九)：Kafka 集成"
date: 2026-04-15
tags:
  - zeek
  - series
  - kafka
  - log-streaming
  - integration
description: "深入解析 Zeek Kafka 集成——Kafka Writer 配置、日志流输出、Kafka Topic、Partition 策略、实战配置"
---

> [!info] Zeek 2026 深度探索系列
> 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-15-zeek-deep-dive-ch1-overview|第一章：Zeek 概述]]
> 2. [[2026-04-15-zeek-deep-dive-ch2-installation|第二章：安装部署]]
> 3. [[2026-04-15-zeek-deep-dive-ch3-config|第三章：配置系统]]
> 4. [[2026-04-15-zeek-deep-dive-ch4-architecture|第四章：Zeek 架构]]
> 5. [[2026-04-15-zeek-deep-dive-ch5-logging|第五章：日志系统]]
> 6. [[2026-04-15-zeek-deep-dive-ch6-scriptlang|第六章：ZeekScript 基础]]
> 7. [[2026-04-15-zeek-deep-dive-ch7-events|第七章：事件]]
> 8. [[2026-04-15-zeek-deep-dive-ch8-hooks|第八章：Hooks]]
> 9. [[2026-04-15-zeek-deep-dive-ch9-packages|第九章：Packages]]
> 10. [[2026-04-15-zeek-deep-dive-ch10-debugging|第十章：调试]]
> 11. [[2026-04-15-zeek-deep-dive-ch11-http|第十一章：HTTP 分析]]
> 12. [[2026-04-15-zeek-deep-dive-ch12-dns|第十二章：DNS 分析]]
> 13. [[2026-04-15-zeek-deep-dive-ch13-tls|第十三章：TLS 分析]]
> 14. [[2026-04-15-zeek-deep-dive-ch14-smb|第十四章：SMB 分析]]
> 15. [[2026-04-15-zeek-deep-dive-ch15-ssh|第十五章：SSH 分析]]
> 16. [[2026-04-15-zeek-deep-dive-ch16-ftp|第十六章：FTP 分析]]
> 17. [[2026-04-15-zeek-deep-dive-ch17-smtp|第十七章：SMTP 分析]]
> 18. [[2026-04-15-zeek-deep-dive-ch18-rdp|第十八章：RDP 分析]]
> 19. **第十九章：Kafka 集成**

---

## 1. Kafka 集成概述

Zeek 支持将日志输出到 Kafka，实现日志流的实时处理。Kafka Writer 是 Zeek 日志输出的重要方式之一。

### 1.1 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                    Zeek Kafka 集成架构                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Zeek Process                                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Log Writer Framework                                 │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  │  │
│  │  │ ASCII   │  │ JSON    │  │ Kafka   │  │ ...     │  │  │
│  │  │ Writer  │  │ Writer  │  │ Writer  │  │         │  │  │
│  │  └─────────┘  └─────────┘  └────┬────┘  └─────────┘  │  │
│  └─────────────────────────────────┼─────────────────────┘  │
│                                    ↓                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │           Kafka Cluster                               │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │  Topic: zeek-http-log                           │  │  │
│  │  │  Topic: zeek-dns-log                            │  │  │
│  │  │  Topic: zeek-ssl-log                            │  │  │
│  │  │  ...                                            │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 支持的 Kafka 版本

- Kafka 0.10.0+
- Broker 版本 0.10.0+
- ZooKeeper 不再需要（KRaft 模式）

---

## 2. Kafka Writer 配置

### 2.1 安装依赖

```bash
# 安装 librdkafka
# Ubuntu/Debian
apt-get install librdkafka-dev

# CentOS/RHEL
yum install librdkafka-devel

# macOS
brew install librdkafka
```

### 2.2 编译安装

```bash
./configure --enable-kafka
make
make install
```

### 2.3 加载 Kafka 脚本

```zeek
@load frameworks/logging/writer/kafka
```

---

## 3. Kafka 配置选项

### 3.1 全局配置

```zeek
# Kafka Writer 全局配置
redef Kafka::logs_to_send = Set();  # 空 = 所有日志

# Broker 配置
redef Kafka::kafka_brokers = Set(["localhost:9092"]);

# Topic 命名
redef Kafka::topic_prefix = "zeek";

# Partition 策略
redef Kafka::partition_type = Kafka::PARTITION_BY_SOURCE;
redef Kafka::key = "";  # Partition key

# 性能调优
redef Kafka::queue_size = 10000;
redef Kafka::max_batch_size = 16384;
redef Kafka::batch_timeout = 100ms;
```

### 3.2 Topic 配置

```zeek
# 每个日志类型对应一个 Topic
# Topic 命名规则: prefix-日志类型
# 例如: zeek-http, zeek-dns, zeek-ssl

# 自定义 Topic 映射
redef Kafka::topic_mapping = {
    ["http"] = "security-http",
    ["dns"] = "security-dns",
    ["ssl"] = "security-ssl",
    ["conn"] = "network-conn",
};
```

### 3.3 分区策略

```zeek
# Kafka Partition 策略
type KafkaPartitionType: enum {
    PARTITION_BY_SOURCE,     # 按源 IP 分区
    PARTITION_BY_TARGET,    # 按目标 IP 分区
    PARTITION_BY_BOTH,       # 按源+目标 IP
    PARTITION_BY_LOG_ID,     # 按日志类型
    PARTITION_BY_ROUND_ROBIN  # 轮询
};

# 常用配置
redef Kafka::partition_type = Kafka::PARTITION_BY_TARGET;
```

---

## 4. 日志输出配置

### 4.1 启用特定日志流

```zeek
# 只发送特定日志到 Kafka
redef Kafka::logs_to_send = set(
    "http",
    "dns",
    "ssl",
    "ssh",
    "smtp",
    "conn"
);
```

### 4.2 禁用特定日志

```zeek
# 排除特定日志
redef Kafka::logs_to_send = set(
    "http", "dns", "ssl", "ssh", "smtp",
    "conn", "notice", "weird", "info"
) - set("conn");
```

### 4.3 完整配置示例

```zeek
@load frameworks/logging/writer/kafka

# Kafka 连接配置
redef Kafka::kafka_brokers = Set([
    "kafka1.example.com:9092",
    "kafka2.example.com:9092",
    "kafka3.example.com:9092"
]);

# Topic 前缀
redef Kafka::topic_prefix = "zeek";

# 发送哪些日志
redef Kafka::logs_to_send = set(
    "http",
    "dns",
    "ssl",
    "smtp",
    "ssh",
    "conn",
    "notice"
);

# 分区策略 - 按目标 IP
redef Kafka::partition_type = Kafka::PARTITION_BY_TARGET;

# 性能参数
redef Kafka::queue_size = 50000;
redef Kafka::max_batch_size = 16384;
redef Kafka::batch_timeout = 100ms;
```

---

## 5. 实战配置

### 5.1 ZeekCluster + Kafka

在集群环境中配置 Kafka Writer：

```zeek
# local.zeek (cluster)

@load frameworks/logging/writer/kafka

# Manager 节点配置
redef Kafka::kafka_brokers = Set(["kafka1:9092", "kafka2:9092"]);

# 只在 Manager 上发送 Kafka
redef Kafka::send_all_logs = F;
redef Kafka::logs_to_send = set("http", "dns", "ssl");
```

### 5.2 TLS 配置

```zeek
# Kafka TLS/SSL 配置
redef Kafka::ssl = T;
redef Kafka::ssl_ca_location = "/etc/ssl/certs/ca-bundle.crt";
redef Kafka::ssl_certificate_location = "/path/to/client.crt";
redef Kafka::ssl_key_location = "/path/to/client.key";

# SASL 认证
redef Kafka::sasl = T;
redef Kafka::sasl_username = "zeek";
redef Kafka::sasl_password = "secret";
redef Kafka::sasl_mechanism = "PLAIN";
```

### 5.3 压缩配置

```zeek
# 压缩
redef Kafka::compression = Kafka::COMPRESSION_GZIP;
# 其他选项: NONE, SNAPPY, LZ4, ZSTD
```

---

## 6. 日志格式

### 6.1 JSON 输出到 Kafka

```bash
# 配置 JSON 格式
zeek -e '@load policies/tuning/json-logs' \
     -e '@load frameworks/logging/writer/kafka'
```

### 6.2 消息结构

```json
{
  "ts": 1672531200.123456,
  "uid": "Cx1234abcd",
  "id.orig_h": "192.168.1.100",
  "id.orig_p": 52341,
  "id.resp_h": "93.184.216.34",
  "id.resp_p": 80,
  "method": "GET",
  "host": "example.com",
  "uri": "/",
  "version": "1.1",
  "user_agent": "Mozilla/5.0",
  "status_code": 200,
  "status_msg": "OK"
}
```

### 6.3 消息头

```bash
# Kafka 消息 Key (用于分区)
# 如果设置 partition_type = PARTITION_BY_SOURCE
# Key = 源 IP 字符串

# 消息 Value
# 完整的 JSON 格式日志行
```

---

## 7. 性能调优

### 7.1 批处理配置

```zeek
# 批处理优化
redef Kafka::max_batch_size = 32768;   # 最大批次 (bytes)
redef Kafka::batch_timeout = 200ms;    # 批次超时
redef Kafka::queue_size = 100000;      # 队列大小
```

### 7.2 压缩

```zeek
# 启用压缩减少网络开销
redef Kafka::compression = Kafka::COMPRESSION_LZ4;
```

### 7.3 连接池

```zeek
# 连接池配置
redef Kafka::metadata_refresh_interval = 5mins;
redef Kafka::socket_timeout = 10s;
```

---

## 8. 监控与故障排除

### 8.1 Kafka Writer 状态

```bash
# 查看 Zeek 状态
zeekctl status

# 查看 Kafka 连接
# 检查 reporter.log 中的错误
```

### 8.2 常见错误

```
# 连接失败
Error: Kafka: Produce failed: Local: Broker transport failure

# Topic 不存在
Error: Kafka: Unknown topic or partition

# 队列满
Warning: Kafka: queue buffer full, dropping messages
```

### 8.3 调试

```bash
# 启用调试输出
zeek -e 'redef Kafka::debug = T;' ...

# 查看 reporter.log
tail -f reporter.log
```

---

## 9. 与 SIEM 集成

### 9.1 Elasticsearch + Kafka

```bash
# 使用 Logstash 或 Beats 消费 Kafka
# logstash.conf
input {
  kafka {
    bootstrap_servers => "kafka1:9092,kafka2:9092"
    topics => ["zeek-http", "zeek-dns", "zeek-ssl"]
    codec => json
  }
}
filter {
  date {
    match => ["ts", "UNIX"]
  }
}
output {
  elasticsearch {
    hosts => ["es1:9200"]
    index => "zeek-%{+YYYY.MM.dd}"
  }
}
```

### 9.2 Splunk

```bash
# Splunk Connect for Kafka
# 使用 HEC 发送到 Splunk
```

---

## 10. 小结

本章介绍了 Zeek Kafka 集成：

| 配置项 | 说明 |
|--------|------|
| **kafka_brokers** | Kafka Broker 地址列表 |
| **topic_prefix** | Topic 名称前缀 |
| **logs_to_send** | 要发送的日志类型 |
| **partition_type** | 分区策略 (源IP/目标IP/轮询) |
| **queue_size** | 内存队列大小 |
| **compression** | 压缩算法 |

Kafka 集成使得 Zeek 可以：
- 实时流式输出日志
- 支持大规模分布式日志处理
- 与 SIEM 系统无缝集成
- 构建实时安全分析管道

通过 Kafka，可以构建现代化的安全运营中心日志架构。
