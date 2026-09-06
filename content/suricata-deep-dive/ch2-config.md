---
title: "Suricata 深度探索 (二)：配置系统"
date: 2026-04-15
tags:
  - suricata
  - series
  - config
  - yaml
  - scconf
description: "深入解析 Suricata 的 YAML 配置解析机制、SCConf 配置树、ConfGet* 系列函数、命令行参数处理，以及配置如何驱动源码行为"
---

> [!info] Suricata 2026 深度探索系列 0. [[suricata-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-overview|第一章：Suricata 概述]]
> 2. **第二章：Suricata 配置系统**
> 3. [[ch3-runmodes|第三章：Runmodes 运行模式]]
> 4. [[ch4-thread-model|第四章：线程模型]]
> 5. [[ch5-capture|第五章：Capture 初始化]]

---

## 1. 配置系统概述

Suricata 使用 **YAML** 作为配置文件格式，通过 **SCConf**（Suricata Config）系统进行解析和访问。

```yaml
# suricata.yaml — 标准配置结构
%YAML 1.1
---
configuration:
  max-pending-packets: 1024
  capture:
    workers: 4
    max-pending-packets: 1024
  detect:
    profile: medium
```

对应 **内存配置树**：

```
ConfTree
└── configuration
    ├── max-pending-packets (1024)
    ├── capture
    │   ├── workers (4)
    │   └── max-pending-packets (1024)
    └── detect
        └── profile ("medium")
```

---

## 2. YAML 配置解析

### 2.1 解析入口

```c
// src/conf-yaml.c — YAML 解析核心
int ConfYamlLoad(const char *filename)
{
    FILE *f = fopen(filename, "r");
    yaml_parser_t parser;

    yaml_parser_initialize(&parser);
    yaml_parser_set_input_file(&parser, f);

    ConfYamlParse(&parser, NULL, NULL, NULL);

    yaml_parser_delete(&parser);
    fclose(f);
    return 0;
}
```

### 2.2 配置节点结构

```c
// src/conf.h — 配置节点定义
typedef struct ConfNode_ {
    char *name;              // 节点名称
    char *value;             // 叶节点的值
    TAILQ_HEAD(,_ConfNode) head;  // 子节点链表
    TAILQ_ENTRY(_ConfNode) next;  // 兄弟节点链表
    struct ConfNode_ *parent;    // 父节点
    int references;           // 引用计数
} ConfNode;

static ConfNode *root = NULL;  // 配置树根节点
```

### 2.3 YAML → ConfNode 解析流程

```c
// src/conf-yaml.c — 递归解析
static int ConfYamlParse(yaml_parser_t *parser, ConfNode *parent, ...)
{
    yaml_event_t event;

    while (1) {
        yaml_parser_parse(parser, &event);

        switch (event.type) {
            case YAML_SCALAR_EVENT: {
                // 创建新节点
                ConfNode *node = ConfNodeNew();
                node->name = strdup((char *)event.data.scalar.value);

                // 解析值（可能为嵌套结构）
                ConfYamlParse(parser, node, ...);

                // 挂载到父节点
                if (parent) {
                    TAILQ_INSERT_TAIL(&parent->head, node, next);
                }
                break;
            }
            case YAML_SEQUENCE_START_EVENT:
                // 处理数组 [...]
                break;
            case YAML_MAPPING_START_EVENT:
                // 处理映射 {k: v}
                break;
            case YAML_STREAM_END_EVENT:
                return 0;
        }
    }
}
```

---

## 3. 配置访问接口

### 3.1 基础读取函数

```c
// src/conf.c — 配置访问 API

// 读取字符串值
int ConfGet(const char *name, const char **value);

// 读取整数值
int ConfGetInt(const char *name, intmax_t *val);

// 读取布尔值
int ConfGetBool(const char *name, int *val);

// 读取节点指针（用于遍历子节点）
ConfNode *ConfNodeLookupChild(const ConfNode *parent, const char *name);

// 遍历所有子节点
TAILQ_FOREACH(ConfNode *node, &parent->head, next)
```

### 3.2 配置使用示例

```yaml
# suricata.yaml
capture:
  mode: af-packet
  threads: 4
  buffer-size: 1024
```

```c
// src/suricata.c — 读取配置
static void SetupCapture(const char *capture_mode)
{
    // 读取线程数
    const char *threads_str;
    if (ConfGet("capture.threads", &threads_str) == 1) {
        ConfGetInt("capture.threads", &cfg->threads);
    }

    // 读取缓冲区大小
    int64_t buffer_size = 1024;
    (void)ConfGetInt("capture.buffer-size", &buffer_size);

    // 遍历所有 capture 下的子节点
    ConfNode *capture_node = ConfGetNode("capture");
    ConfNode *child;
    TAILQ_FOREACH(child, &capture_node->head, next) {
        printf("  %s = %s\n", child->name, child->value);
    }
}
```

---

## 4. 命令行参数处理

### 4.1 选项解析

```c
// src/suricata.c — 命令行选项定义
static struct option long_options[] = {
    {"af-packet", optional_argument, 0, 'i'},
    {"capture-count", required_argument, 0, 'c'},
    {"conf", required_argument, 0, 'C'},
    {"config", required_argument, 0, 'c'},
    {"datadir", required_argument, 0, 0},
    {"debug", optional_argument, 0, 'd'},
    {"disable-detect", no_argument, 0, 'e'},
    {"dump-config", no_argument, 0, 0},
    {"eeprom", optional_argument, 0, 0},
    // ... 更多选项
    {0, 0, 0, 0}
};
```

### 4.2 选项处理流程

```c
// src/suricata.c — 主函数中的参数解析
int main(int argc, char **argv)
{
    int opt;
    while ((opt = getopt_long(argc, argv, "c:C:d:ei:o:p:q:r:s:t:T:u:v:",
                             long_options, NULL)) != -1) {
        switch (opt) {
            case 'c':
                // -c, --conf, --config: 指定配置文件
                conf_filename = optarg;
                break;
            case 'C':
                // -C: 仅运行配置验证（不启动）
                conf_test = true;
                break;
            case 'i':
                // -i: 指定接口（af-packet/pcap）
                if (optarg)
                    SCSetInterface(optarg);
                break;
            case 'T':
                // -T: 测试配置（加载但不运行）
                conf_test = true;
                break;
        }
    }
}
```

### 4.3 配置优先级

Suricata 配置按以下优先级覆盖（高 → 低）：

```
1. 命令行参数 (-c suricata-custom.yaml)
2. 环境变量 (SURICATA_CONF=/path/to/conf)
3. 默认配置 (suricata.yaml in --default-path)
```

---

## 5. 配置树操作

### 5.1 合并配置

Suricata 支持 **配置Includes**：

```yaml
# suricata.yaml
includes:
  - /etc/suricata/rules/custom.rules
  - /etc/suricata/axis.yaml
```

```c
// src/conf.c — 配置合并
int ConfYamlLoad(const char *filename)
{
    // 先加载主配置
    ConfYamlLoadFile(filename);

    // 遍历 includes
    ConfNode *includes = ConfGetNode("includes");
    if (includes) {
        ConfNode *inc;
        TAILQ_FOREACH(inc, &includes->head, next) {
            ConfYamlLoadFile(inc->value);  // 递归加载并合并
        }
    }
}
```

### 5.2 配置重载

Suricata 支持 **运行时重载配置**（SIGHUP 信号）：

```c
// src/suricata.c — 信号处理
static void SignalHandler(void)
{
    if (signo == SIGHUP) {
        // 重新加载配置
        ConfYamlLoad(conf_filename);
        // 重新初始化检测引擎
        DetectEngineReload();
    }
}
```

---

## 6. 关键配置项源码映射

### 6.1 `max-pending-packets`

```yaml
# suricata.yaml
max-pending-packets: 1024
```

```c
// src/suricata.c — 配置读取
static int ParseSize(const char *size, uint32_t *res)
{
    // 解析 1024, 1K, 1M 等格式
}

intmain(void)
{
    // 读取 max-pending-packets
    uint32_t max_pending_packets = 1024;
    (void)ConfGetInt("max-pending-packets", &max_pending_packets);

    // 设置到全局配置
    g_default_packet_size = max_pending_packets;
}
```

### 6.2 `runmode`

```yaml
# suricata.yaml
runmode: auto
```

```c
// src/runmode.c — 运行模式配置
typedef enum {
    RUNMODE_UNKNOWN,
    RUNMODE_PCAP_DEV,      // 单网卡抓包
    RUNMODE_WORKER,        // 多线程 Worker 模式
    RUNMODE_AUTOFP,        // 自动分配filedescriptor
    RUNMODE_NETMAP,
    RUNMODE_AF_PACKET,
    RUNMODE_NFQ,
    RUNMODE_IPFW,
    RUNMODE_UNITTEST,
    RUNMODE_DPDK,
} RunMode;

int RunModeSet(runmode, capture_plugin, ...);
```

### 6.3 `outputs.eve-log`

```yaml
# suricata.yaml
outputs:
  -eve-log:
    enabled: yes
    filename: eve.json
    types:
      - alert
      - http
      - dns
```

```c
// src/output-eve.c — EVE 日志配置
typedef struct OutputEveFile_ {
    const char *filename;
    bool jsonevent;
    bool http;
    bool dns;
    // ...
} OutputEveFile;

int OutputEveLoadConfig(const ConfNode *conf)
{
    const char *enabled;
    if (ConfGet("outputs.eve-log.enabled", &enabled) == 1) {
        g_eve_enabled = (strcmp(enabled, "yes") == 0);
    }

    // 读取各模块开关
    ConfNode *types = ConfGetNode("outputs.eve-log.types");
    ConfNode *type;
    TAILQ_FOREACH(type, &types->head, next) {
        if (strcmp(type->name, "http") == 0) {
            g_eve_http = true;
        }
    }
}
```

---

## 7. 配置验证

### 7.1 配置检查模式

```bash
# 不运行，仅检查配置语法
suricata -T -c /etc/suricata/suricata.yaml

# 验证规则语法
suricata -T -c /etc/suricata/suricata.yaml -S /etc/suricata/rules/*.rules
```

### 7.2 配置转储

```bash
# 转储解析后的配置树（JSON 格式）
suricata --dump-config

# 输出示例
{
  "max-pending-packets": 1024,
  "capture": {
    "threads": 4,
    "buffer-size": 1024
  },
  "detect": {
    "profile": "medium"
  }
}
```

---

## 8. 小结

本章解析了 Suricata 配置系统的核心机制：

1. **YAML → ConfNode**：通过 libyaml 将配置文件解析为树形内存结构
2. **SCConf API**：提供 `ConfGet*`、`ConfGetNode` 系列函数访问配置
3. **命令行优先级**：命令行参数 > 环境变量 > 默认配置
4. **配置合并**：通过 includes 机制支持多文件配置

下一章我们将深入 **Runmodes**，解析 `runmode: auto/worker/nfq` 等模式如何影响线程拓扑。
