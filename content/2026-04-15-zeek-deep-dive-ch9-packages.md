---
title: "Zeek 深度探索 (九)：Packages"
date: 2026-04-15
tags:
  - zeek
  - series
  - packages
  - zkg
  - script-loading
  - modularity
description: "深入解析 Zeek 脚本组织机制——@load 指令、脚本路径（zeek_path）、ZKG（Zeek Package Manager）、Package 结构、__load__.zeek、模块（Module）概念"
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
> 9. **第九章：Packages**

---

## 1. 脚本组织概述

Zeek 脚本（ZeekScript）通过 `@load` 指令和 **zeek_path** 路径系统组织成模块化的**包（Package）**。理解这套机制是编写复杂 Zeek 脚本和第三方插件的基础。

### 1.1 脚本加载层次

```
┌─────────────────────────────────────────────────────────────┐
│                    Zeek 脚本加载层次                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  zeek -i eth0 scripts/site/my-script.zeek                   │
│         │                                                    │
│         ├── 加载顺序：                                        │
│         │                                                    │
│         │  1. @load scripts/base/frameworks/intel           │
│         │     └── 内置框架（base）                            │
│         │                                                    │
│         │  2. @load-sigs etc/sig.sig                        │
│         │     └── 签名文件                                    │
│         │                                                    │
│         │  3. @load scripts/base/protocols/http             │
│         │     └── 协议分析器                                  │
│         │                                                    │
│         │  4. scripts/site/my-script.zeek                   │
│         │     └── 本地站点脚本                                │
│         │                                                    │
│         └── 加载机制：                                        │
│                                                              │
│             zeek_path = /usr/local/zeek/share/zeek/site:...  │
│                           │                                  │
│                           ↓                                  │
│                    脚本查找路径                               │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 脚本加载流程

```
┌─────────────────────────────────────────────────────────────┐
│                    脚本加载流程                               │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. 解析命令行 @load 指令                                     │
│         │                                                    │
│         ↓                                                    │
│  2. 在 zeek_path 中查找脚本文件                               │
│         │                                                    │
│         ↓                                                    │
│  3. 读取脚本内容                                              │
│         │                                                    │
│         ↓                                                    │
│  4. 预处理（@define, @if, @load 等）                         │
│         │                                                    │
│         ↓                                                    │
│  5. 编译为字节码（.zo 文件）                                  │
│         │                                                    │
│         ↓                                                    │
│  6. 执行字节码                                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. @load 指令

### 2.1 基本用法

`@load` 指令用于加载另一个 Zeek 脚本文件：

```zeek
# 加载内置协议分析器
@load scripts/base/protocols/http
@load scripts/base/protocols/dns
@load scripts/base/protocols/ssl

# 加载框架
@load scripts/base/frameworks/intel
@load scripts/base/frameworks/files
@load scripts/base/frameworks/logging

# 加载策略脚本
@load scripts/base/policy/misc/scan
@load scripts/base/policy/protocols/http/header-names
```

### 2.2 加载本地脚本

```zeek
# 加载当前目录下的脚本
@load my-script.zeek

# 加载指定路径的脚本
@load /opt/zeek/scripts/my-custom-script

# 加载 site 目录下的脚本（相对路径）
@load site/my-detection-script
```

### 2.3 条件加载

```zeek
# 基于配置变量条件加载
@if (Site::use_custom_detection)
    @load site/custom-detection
@endif

# 基于 Zeek 版本加载
@if (zeek_version >= 7000)
    @load scripts/base/protocols/http
@endif

# 基于命令行宏加载
@if (DEBUG_MODE)
    @load scripts/base/misc/debug
@endif
```

---

## 3. zeek_path 脚本路径

### 3.1 默认 zeek_path

`zeek_path` 定义了 Zeek 查找脚本文件的路径列表（冒号分隔）：

```
# 默认 zeek_path 通常包含：
/usr/local/zeek/share/zeek/scripts/base
/usr/local/zeek/share/zeek/scripts/site
/usr/local/zeek/share/zeek/scripts/policy
...
```

### 3.2 配置 zeek_path

```bash
# 环境变量方式
export ZEEKPATH=/opt/zeek/share:/opt/zeek/scripts:$ZEEKPATH

# 命令行方式
zeek -i eth0 -e 'redef zeek_path = "/opt/zeek/scripts:/usr/local/zeek/share/zeek"'

# zeekctl 配置（etc/zeekctl.cfg）
# zeek_path = /opt/zeek/share/zeek:/usr/local/zeek/share/zeek
```

### 3.3 脚本查找规则

```
查找 my-script.zeek 时：
┌─────────────────────────────────────────────────────────────┐
│  1. 检查是否为绝对路径                                        │
│     /opt/zeek/scripts/my-script.zeek  ✓                     │
│                                                              │
│  2. 在 zeek_path 中逐目录查找                                │
│     For each dir in zeek_path:                              │
│       dir/my-script.zeek  ✓                                  │
│                                                              │
│  3. 查找 __load__.zeek（目录加载）                           │
│     dir/__load__.zeek  ✓ (如果加载的是目录)                   │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. Package 结构

### 4.1 标准 Package 目录结构

```
zeek-my-package/
├── __load__.zeek           # Package 入口脚本（必须）
├── package.json            # Package 元数据
├── scripts/
│   ├── main.zeek           # 主脚本
│   ├── lib.zeek           # 库/辅助函数
│   └── types.zeek         # 类型定义
├── etc/
│   └── config.zeek         # 配置脚本
├── testing/
│   └── test.zeek           # 测试脚本
└── README.md               # 文档
```

### 4.2 __load__.zeek

`__load__.zeek` 是 Package 的**入口脚本**，当 Package 被 `@load` 时自动执行：

```zeek
# __load__.zeek
# Package: zeek-my-detector

@load base/frameworks/sumstats
@load base/frameworks/intel

# 加载子模块
@load ./scripts/detector
@load ./scripts/reporter

# 设置配置
redef MyDetector::enabled = T;
redef MyDetector::threshold = 100;

print "zeek-my-detector loaded";
```

### 4.3 package.json

```json
{
    "name": "zeek/my-detector",
    "version": "1.0.0",
    "description": "Custom detection package for Zeek",
    "main": "__load__.zeek",
    "dependencies": {
        "zeek/intel": ">=1.0.0"
    },
    "author": "Your Name",
    "license": "BSD-3-Clause"
}
```

---

## 5. ZKG（Zeek Package Manager）

### 5.1 ZKG 简介

**ZKG**（Zeek Package Manager）是官方包管理工具，用于安装、升级、分享 Zeek 包：

```bash
# 安装 ZKG（如果未预装）
pip install zkg

# 或者通过 zeekctl
zeekctl install
```

### 5.2 基本命令

```bash
# 搜索包
zkg search intel
zkg search "threat detection"
zkg search --author "Corelight"

# 安装包
zkg install zeek/intel
zkg install corelight/zeek-af_packet

# 列出已安装包
zkg list

# 升级包
zkg upgrade zeek/intel

# 卸载包
zkg remove zeek/intel

# 验证包
zkg verify zeek/intel
```

### 5.3 安装来自不同源

```bash
# 官方_packages.yml 源
zkg install zeek/intel

# GitHub 仓库
zkg install https://github.com/zeek/zeek/issues/...

# 本地目录
zkg install /path/to/local/package

# Git 分支
zkg install https://github.com/user/zeek-package --branch develop
```

### 5.4 ZKG 源配置

```bash
# 查看当前源
zkg source

# 添加自定义源
zkg source add my-source https://raw.githubusercontent.com/user/zeek-packages/main/packages.yml

# 官方源
zkg source add official https://packages.zeek.org/packages.yml
```

---

## 6. 模块（Module）系统

### 6.1 模块定义

Zeek 的**模块（Module）** 用于**命名空间隔离**，避免全局变量冲突：

```zeek
module MyModule;

export {
    # 导出的类型、变量、函数
    type MyRecord: record {
        ts: time;
        msg: string;
    };

    global my_var: count = 0;

    function helper(): string {
        return "helper";
    }
}

# 非导出内容（模块内部私有）
local secret = "private";
```

### 6.2 使用模块

```zeek
# 使用 :: 访问模块成员
event zeek_init() {
    local r: MyModule::MyRecord = [
        $ts = current_time(),
        $msg = MyModule::helper()
    ];

    MyModule::my_var = MyModule::my_var + 1;
    print fmt("Count: %s", MyModule::my_var);
}
```

### 6.3 内置模块

```
┌─────────────────────────────────────────────────────────────┐
│                    Zeek 内置模块                             │
├─────────────────────────────────────────────────────────────┤
│  • Global                          全局函数和常量              │
│  • Log                            日志系统                    │
│  • Intel                          威胁情报框架                 │
│  • Notice                         告警框架                    │
│  • Reporter                       报告/错误                  │
│  • SumStats                       聚合统计框架                │
│  • FileAnalysis                   文件分析框架                │
│  • PacketAnalyzer                 数据包分析器                │
│  • Auth                            认证框架                   │
└─────────────────────────────────────────────────────────────┘
```

### 6.4 模块与 @load

```zeek
# 在一个脚本中定义模块
module MyDetector;

export {
    type Info: record {
        ts: time;
        src: addr;
        detected: bool;
    };
}

global detections: vector of Info;

function add_detection(src: addr) {
    detections += [$ts=current_time(), $src=src, $detected=T];
}

# 在另一个脚本中使用
@load ./my-detector

event some_event(src: addr) {
    MyDetector::add_detection(src);
}
```

---

## 7. @import 指令

### 7.1 @import 与 @load

- `@load`：加载脚本文件，**执行**其顶层代码
- `@import`：导入模块，**仅引入命名空间**，不执行模块代码

```zeek
# @load：加载并执行脚本
@load scripts/base/frameworks/intel
# → 执行 intel 框架的初始化代码

# @import：导入模块（仅引入命名空间）
@import Intel;

event zeek_init() {
    # 使用 Intel:: 开头的类型
    local data: Intel::Info = [...];
}
```

### 7.2 @import 示例

```zeek
# 导入日志模块
@import Log;

# 导入通知模块
@import Notice;

# 使用导入的类型
event connection_established(c: connection) {
    Notice::weird([$note = Notice::Activity, ...]);
}
```

---

## 8. @prefixes 与脚本前缀

### 8.1 @prefixes 配置

`@prefixes` 用于设置脚本的**加载前缀**，影响事件处理程序的默认行为：

```zeek
# 设置前缀
@prefixes = "custom";

# 加载脚本后，以下事件处理程序会被注册为 custom_event_name
event event_name() {
    # 实际注册为 custom::event_name
}
```

### 8.2 使用场景

```zeek
# 在 site 脚本中
@prefixes = "site";

@load protocols/http

# http_request 事件处理程序
# 会同时注册为 http_request 和 site::http_request
```

---

## 9. 脚本加载最佳实践

### 9.1 加载顺序

```
# 推荐的加载顺序
@load base/frameworks/sumstats      # 1. 基础框架
@load base/frameworks/intel         # 2. 情报框架
@load base/frameworks/notice       # 3. 通知框架

@load protocols/dns                 # 4. 协议分析器
@load protocols/http
@load protocols/ssl

@load policy/misc/scan              # 5. 策略脚本
@load policy/protocols/http/...

@load site/local                    # 6. 本地脚本（最后）
```

### 9.2 避免重复加载

```zeek
# 使用 @ifndef 防止重复加载
@ifndef MY_SCRIPT_LOADED
@define MY_SCRIPT_LOADED

# ... 脚本内容 ...

@endif
```

### 9.3 脚本组织示例

```
scripts/site/my-nsm/
├── __load__.zeek           # 入口：加载所有子模块
├── config.zeek             # 配置变量
├── detectors/
│   ├── __load__.zeek
│   ├── brute-force.zeek
│   ├── dns-tunnel.zeek
│   └── exfiltration.zeek
├── logging/
│   ├── __load__.zeek
│   └── custom-logging.zeek
└── utils/
    ├── __load__.zeek
    └── helpers.zeek
```

---

## 10. ZKG Package 开发

### 10.1 创建新 Package

```bash
# 初始化 Package 结构
zkg init my-zeek-package

# 创建目录
mkdir -p my-zeek-package/{scripts,etc,testing}
touch my-zeek-package/{__load__.zeek,scripts/main.zeek}
```

### 10.2 Package.json 示例

```json
{
    "name": "zeek/my-zeek-package",
    "version": "0.1.0",
    "description": "My custom Zeek analysis package",
    "main": "__load__.zeek",
    "dependencies": {},
    "scripts": {
        "test": "zeek -b test.zeek"
    },
    "license": "BSD-3-Clause"
}
```

### 10.3 发布 Package

```bash
# 1. 在 GitHub 创建仓库
# 2. 添加 packages.yml 到仓库根目录

# packages.yml 示例
- name: zeek/my-package
  version: 1.0.0
  description: My custom package
  tags:
    - detection
    - analysis
  url: https://github.com/user/zeek-my-package
  manifest: __load__.zeek

# 3. 在 GitHub Releases 发布
# 4. 向官方 packages.yml 提交 PR
```

---

## 11. 实战：构建自定义检测 Package

### 11.1 目录结构

```
zeek-suspicious-detector/
├── __load__.zeek
├── package.json
├── scripts/
│   ├── __load__.zeek
│   ├── main.zeek
│   ├── brute-force.zeek
│   └── data-exfil.zeek
├── etc/
│   └── config.zeek
└── testing/
    └── test.zeek
```

### 11.2 __load__.zeek

```zeek
@load base/frameworks/sumstats
@load base/frameworks/notice
@load protocols/ssh

# 配置
redef SuspiciousDetector::enable_brute_force = T;
redef SuspiciousDetector::enable_data_exfil = T;
redef SuspiciousDetector::threshold = 10;

# 加载检测器
@load ./scripts/brute-force
@load ./scripts/data-exfil

print "SuspiciousDetector loaded";
```

### 11.3 brute-force.zeek

```zeek
module SuspiciousDetector;

export {
    redef enum Notice::Type += {
        BruteForceAttempt
    };
}

global ssh_failures: table[addr] of count;

event ssh_auth_success(c: connection) {
    local ip = c$id$orig_h;

    # 清零失败计数
    if (ip in ssh_failures) {
        delete ssh_failures[ip];
    }
}

event ssh_auth_failed(c: connection, code: count) {
    local ip = c$id$orig_h;

    if (ip !in ssh_failures) {
        ssh_failures[ip] = 0;
    }

    ssh_failures[ip]++;

    if (ssh_failures[ip] >= threshold) {
        NOTICE([$note = BruteForceAttempt,
                $src = ip,
                $msg = fmt("SSH brute force: %d failures", ssh_failures[ip]),
                $identifier = cat(ip)]);
    }
}
```

### 11.4 配置脚本 etc/config.zeek

```zeek
module SuspiciousDetector;

export {
    const enable_brute_force = T;
    const enable_data_exfil = T;
    const threshold = 10;
    const exfil_threshold_mb = 100;
}
```

---

## 12. 本章小结

本章介绍了 Zeek 的脚本组织和包管理机制：

1. **@load 指令**：加载其他 ZeekScript 文件，支持相对/绝对路径
2. **zeek_path**：脚本查找路径列表，支持多目录
3. **Package 结构**：`__load__.zeek` 入口、`package.json` 元数据
4. **ZKG**：官方包管理器，`zkg install/search/remove` 命令
5. **模块系统**：命名空间隔离，`module Name; ... export { ... }`
6. **@import**：仅导入命名空间，不执行脚本代码
7. **脚本最佳实践**：加载顺序、重复加载防护、目录组织
8. **Package 开发**：创建、测试、发布完整流程

**下一章**将介绍 **调试**——如何调试 Zeek 脚本，包括 `zeek -b` 调试模式、`print` 语句、`printf` 格式化、以及 script coverage 分析。

> [!tip] 延伸阅读
> - [Zeek Package Manager](https://docs.zeek.org/en/stable/packages/)
> - [ZKG GitHub Repository](https://github.com/zeek/packages)
> - [Zeek Script Loading](https://docs.zeek.org/en/stable/scripts/base/init.zeek)
