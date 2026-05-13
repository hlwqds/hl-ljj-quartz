---
title: "Zeek 深度探索 (六)：ZeekScript 基础"
date: 2026-04-15
tags:
  - zeek
  - series
  - zeek-script
  - types
  - record
  - table
  - set
  - vector
description: "深入解析 ZeekScript 类型系统——基本类型（bool/int/count/double/string/time/interval/addr/subnet）、复合类型（record/table/set/vector）、类型转换、操作符、变量作用域、内置常量和函数"
---

> [!info] Zeek 2026 深度探索系列
> 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-15-zeek-deep-dive-ch1-overview|第一章：Zeek 概述]]
> 2. [[2026-04-15-zeek-deep-dive-ch2-installation|第二章：安装部署]]
> 3. [[2026-04-15-zeek-deep-dive-ch3-config|第三章：配置系统]]
> 4. [[2026-04-15-zeek-deep-dive-ch4-architecture|第四章：Zeek 架构]]
> 5. [[2026-04-15-zeek-deep-dive-ch5-logging|第五章：日志系统]]
> 6. **第六章：ZeekScript 基础**

---

## 1. ZeekScript 概述

ZeekScript 是 Zeek 的脚本语言，用于编写**事件处理程序（Event Handlers）**、**策略脚本（Policy Scripts）** 和**自定义分析逻辑**。它是一种**强类型、面向对象**的脚本语言，语法受 C++ 和 Python 影响，但有独特的设计理念。

### 1.1 语言特性

```
┌────────────────────────────────────────────────────────────┐
│                    ZeekScript 特性                          │
├────────────────────────────────────────────────────────────┤
│  • 强类型系统（编译时 + 运行时双重检查）                       │
│  • 面向对象（record 类型，类似于 C struct）                  │
│  • 事件驱动（事件处理程序是核心执行单元）                      │
│  • 垃圾回收（自动内存管理）                                   │
│  • 函数为一等公民（first-class functions）                   │
│  • 无整数溢出（自动升级为 count/bigint）                      │
│  • 网络类型原生支持（addr, subnet, port）                    │
└────────────────────────────────────────────────────────────┘
```

### 1.2 基本语法结构

```zeek
# 变量声明
global x: count = 42;
local y = 100;           # 类型推断

# 函数定义
function add(a: count, b: count): count {
    return a + b;
}

# 事件处理程序
event zeek_init() {
    print "Zeek initialized";
}

# record 类型定义
type MyRecord: record {
    ts: time;
    src: addr;
    dst: addr;
    bytes: count;
};
```

---

## 2. 基本类型系统

ZeekScript 的基本类型（Primitive Types）包括布尔、数值、字符串、时间等类型。

### 2.1 布尔类型

```zeek
global is_active: bool = T;      # True
global is_debug: bool = F;       # False
local skip = is_active && !is_debug;
```

布尔常量只有 `T` 和 `F`（大写），不支持 `true/false`。

### 2.2 整数类型

ZeekScript 的数值类型分为有符号和无符号两类：

| 类型 | 说明 | 示例 |
| :--- | :--- | :--- |
| `int` | 有符号整数（64位） | `-42`, `0`, `1234` |
| `count` | 无符号整数（64位） | `42`, `0`, `1234` |
| `double` | 双精度浮点 | `3.14`, `2.71828` |

```zeek
local a: int = -100;
local b: count = 200;
local c: double = 3.14159;

# 算术运算
local sum: int = a + b;       # 100（隐式转换）
local product: count = b * 2;  # 400

# 溢出行为
local very_large: count = 2^63;  # 9223372036854775808
```

> [!warning] 整数溢出
> `int` 溢出是**未定义行为**，而 `count` 是无符号的，会自动取模。生产环境中避免对 `int` 进行可能溢出的运算。

### 2.3 字符串类型

ZeekScript 的 `string` 是**不可变（immutable）**的 Unicode 字符串：

```zeek
local s1: string = "Hello";
local s2 = 'World';              # 单引号也可以
local s3 = "Zeek " + s2;         # 字符串连接
local s4 = fmt("%s %s", s3, 42); # 格式化

# 字符串操作
local len = |s1|;                # 长度：5
local substr = s1[1:3];          # 子串："el"（字节索引，非字符）
local contains = "He" in s1;    # T，包含检查
```

```zeek
# 常用字符串函数
local upper = to_upper(s1);      # "HELLO"
local lower = to_lower(s1);      # "hello"
local stripped = strip("  test  ");  # "test"
local joined = join_string_array(split("a,b,c", ","), "-");  # "a-b-c"
```

### 2.4 时间类型

`time` 类型表示时间点，`interval` 类型表示时间间隔：

```zeek
# 获取当前时间
local now: time = current_time();

# 时间间隔
local dur: interval = 5 secs;    # 5 秒
local dur2 = 1 min + 30 secs;    # 1 分 30 秒
local dur3 = 2 hrs;              # 2 小时

# 时间运算
local later = now + dur;         # 时间点 + 间隔 = 时间点
local elapsed: interval = now - some_past_time;  # 时间点相减 = 间隔

# 转换为数值
local secs = dur/sec;            # 5.0（秒）
local ms = dur/1msec;            # 5000.0（毫秒）
local trunc_secs = dur/1sec;     # 5（截断）
```

> [!info] interval 字面量
> ```
> 100 msec    # 100 毫秒
> 5 sec       # 5 秒
> 3 min       # 3 分钟
> 2 hrs       # 2 小时
> 1 day       # 1 天
> ```

### 2.5 网络类型

ZeekScript 原生支持网络相关类型，这是它区别于通用语言的重要特性：

```zeek
# IP 地址
local ip4: addr = 192.168.1.1;
local ip6: addr = fe80::1;
local ip_str = "10.0.0.1";

# 子网
local net: subnet = 192.168.0.0/16;
local net2: subnet = 10.0.0.0/8;

# 判断关系
local in_same_subnet = ip4 in net;          # T
local is_private = 10.0.0.1 in 10.0.0.0/8;  # T

# IP 地址属性
local is_priv = is_private_ip(ip4);         # 检查私有地址
local ip_class = ip4 / 8;                  # 192（取前 8 位）
```

### 2.6 端口类型

```zeek
local http_port: port = 80/tcp;
local https_port: port = 443/tcp;
local dns_port: port = 53/udp;

# 端口属性
local p_num = http_port$port;      # 80
local p_proto = http_port$proto;   # tcp

# 端口比较
local is_web = http_port == 80/tcp;  # T
```

### 2.7 基本类型完整对照表

| 类型 | 说明 | 示例 | 默认值 |
| :--- | :--- | :--- | :--- |
| `bool` | 布尔 | `T`, `F` | `F` |
| `int` | 有符号整数 | `-42`, `0` | `0` |
| `count` | 无符号整数 | `42`, `0` | `0` |
| `double` | 双精度浮点 | `3.14` | `0.0` |
| `string` | 不可变字符串 | `"hello"` | `""` |
| `time` | 时间点 | `current_time()` | `double(0)` |
| `interval` | 时间间隔 | `5 secs` | `0secs` |
| `addr` | IP 地址 | `192.168.1.1` | 未定义 |
| `subnet` | IP 子网 | `10.0.0.0/8` | 未定义 |
| `port` | 端口 | `80/tcp` | `0/unknown` |

---

## 3. 复合类型

ZeekScript 的复合类型（Composite Types）包括 `record`、`table`、`set` 和 `vector`。

### 3.1 record 类型

`record` 是 ZeekScript 最核心的类型，类似于 C 的 `struct`，用于表示结构化数据：

```zeek
# 定义 record 类型
type ConnInfo: record {
    orig_h: addr;
    orig_p: port;
    resp_h: addr;
    resp_p: port;
    bytes: count;
};

# 声明 record 变量
global c: ConnInfo;

# 创建 record 实例（使用 $ 前缀赋值字段）
c$orig_h = 192.168.1.1;
c$orig_p = 12345/tcp;
c$resp_h = 10.0.0.1;
c$resp_p = 80/tcp;
c$bytes = 1024;

# 创建时直接赋值
local c2: ConnInfo = [
    $orig_h = 192.168.1.2,
    $orig_p = 54321/tcp,
    $resp_h = 10.0.0.2,
    $resp_p = 443/tcp,
    $bytes = 2048
];

# 访问字段（使用 $ 前缀）
print c$orig_h;         # 192.168.1.1
print c2$bytes;         # 2048

# 可选字段（?$ 前缀）
c?$orig_bytes;          # 检查字段是否存在（返回 bool）
```

> [!tip] record 的本质
> record 是**值类型**，赋值时是**复制**。如果需要引用语义，使用 `&` 引用修饰符。

### 3.2 table 类型

`table` 是**关联数组**（Associative Array），key-value 键值对的无序集合：

```zeek
# 定义 table[key_type] of value_type
global ip_map: table[addr] of string;
global port_map: table[port] of count;
global complex: table[string] of table[addr] of count;

# 添加元素
ip_map[192.168.1.1] = "workstation-1";
ip_map[192.168.1.2] = "workstation-2";

# 访问元素
local name = ip_map[192.168.1.1];  # "workstation-1"

# 检查 key 是否存在
if (192.168.1.1 in ip_map) {
    print "Found";
}

# 删除元素
delete ip_map[192.168.1.2];

# table 大小
local size = |ip_map|;  # 1
```

```zeek
# table 内置操作
local keys = keys(ip_map);        # 所有 key 的 vector
local vals = values(ip_map);      # 所有 value 的 vector
local pairs = entries(ip_map);    # 所有 (key, value) 对

# 遍历 table
for (ip, name in ip_map) {
    print fmt("%s -> %s", ip, name);
}
```

### 3.3 set 类型

`set` 是**不重复元素的无序集合**：

```zeek
# 定义 set
global ip_set: set[addr];
global str_set: set[string];
global port_set: set[port];

# 添加元素
add ip_set[192.168.1.1];
add ip_set[192.168.1.2];

# 检查元素
if (192.168.1.1 in ip_set) {
    print "IP is in set";
}

# 删除元素
delete ip_set[192.168.1.2];

# 集合运算
global set1: set[string] = {"a", "b", "c"};
global set2: set[string] = {"b", "c", "d"};

local union = set1 | set2;       # {"a", "b", "c", "d"}
local inter = set1 & set2;       # {"b", "c"}
local diff = set1 - set2;        # {"a"}
local sym_diff = set1 ^ set2;    # {"a", "d"}（对称差）
```

### 3.4 vector 类型

`vector` 是**动态数组**（类似 Python list），元素按顺序存储：

```zeek
# 定义 vector
global ips: vector of string;
local nums: vector of count;

# 添加元素
ips += "192.168.1.1";
ips += "192.168.1.2";
ips += "10.0.0.1";

# 访问元素（0-indexed）
local first = ips[0];            # "192.168.1.1"
local last = ips[|ips|-1];       # "10.0.0.1"

# 切片操作
local first_two = ips[0:2];      # ["192.168.1.1", "192.168.1.2"]

# 长度
local len = |ips|;               # 3

# vector 常用函数
local sorted = sort(ips);        # 排序
local rev = reverse(ips);        # 反转
local sum_val = sum(nums);       # 求和（仅数值类型）
```

### 3.5 复合类型对比

| 类型 | 特性 | 示例 |
| :--- | :--- | :--- |
| `record` | 结构化数据，命名字段 | `[$x=1, $y="test"]` |
| `table` | 关联数组，key-value | `[192.168.1.1 -> "host1"]` |
| `set` | 无序不重复集合 | `{"a", "b", "c"}` |
| `vector` | 有序可重复数组 | `["a", "b", "a"]` |

---

## 4. 类型转换与操作符

### 4.1 显式类型转换

```zeek
# 字符串转换
local s = cat(42);                    # "42"（count → string）
local s2 = cat(3.14);                 # "3.14"（double → string）
local s3 = fmt("%.2f", 3.14159);     # "3.14"（格式化）

# 数值转换
local i = integer_to_int("42");       # 字符串 → int
local c = to_count("123");           # 字符串 → count
local d = to_double("3.14");         # 字符串 → double

# 网络类型转换
local ip = to_addr("192.168.1.1");    # 字符串 → addr
local net = to_subnet("10.0.0.0/8");  # 字符串 → subnet

# time 转换
local t = double_to_time(1713206400.0);  # double → time
local ts = strftime("%Y-%m-%d", t);       # time → 格式化字符串

# IP/数值互转
local ip_num = ip_to_num(192.168.1.1);    # addr → count
local num_ip = num_to_ip(3232235777);     # count → addr
```

### 4.2 操作符

```zeek
# 算术操作符
local a = 10 + 5;    # 15（加）
local b = 10 - 5;    # 5（减）
local c = 10 * 5;    # 50（乘）
local d = 10 / 5;    # 2（除）
local e = 10 % 3;    # 1（取模）
local f = 2^10;      # 1024（幂）

# 比较操作符
local cmp = 10 == 10;   # T
local neq = 10 != 5;   # T
local lt = 10 < 5;     # F
local le = 10 <= 10;   # T
local gt = 10 > 5;     # T
local ge = 10 >= 10;   # T

# 逻辑操作符
local and = T && F;    # F（与）
local or = T || F;     # T（或）
local not = !T;        # F（非）

# 位操作符（用于 count）
local and_bit = 0b1010 & 0b1100;  # 0b1000 = 8
local or_bit = 0b1010 | 0b1100;   # 0b1110 = 14
local xor_bit = 0b1010 ^ 0b1100;  # 0b0110 = 6
local shl = 0b0001 << 2;          # 0b0100 = 4
local shr = 0b1000 >> 2;          # 0b0010 = 2
```

---

## 5. 变量与作用域

### 5.1 变量声明

```zeek
# 全局变量
global global_var: count = 100;       # 全局作用域
global counter = 0;                   # 类型推断

# 局部变量
function my_func() {
    local local_var = 50;             # 函数作用域
    global counter = counter + 1;     # 修改全局变量
}

# 常量（不可修改）
const MAX_RETRIES = 3;
const DEFAULT_PORT = 80/tcp;
```

### 5.2 作用域规则

```zeek
global x = 10;

function scope_demo() {
    local x = 20;                    # 遮蔽（shadow）全局变量 x
    print x;                         # 20（局部变量）

    # 在函数内访问全局变量
    print ::x;                       # 10（全局变量）
}

event zeek_done() {
    scope_demo();
}
```

> [!warning] 变量遮蔽（Shadowing）
> 局部变量的名称不能与全局变量相同（编译器会报错），但可以用 `::` 前缀显式引用全局变量。

### 5.3 特殊作用域

```zeek
# 局部作用域（block scope）
if (condition) {
    local tmp = "block-scoped";
    print tmp;
}
# print tmp;  # 错误：tmp 在此处不可见

# @if/@else 预处理作用域
@if (DEBUG)
    global debug_mode = T;
@else
    global debug_mode = F;
@endif
```

---

## 6. 函数

### 6.1 函数定义与调用

```zeek
# 基本函数
function add(a: count, b: count): count {
    return a + b;
}

# 无返回值函数
function log_msg(msg: string) {
    print fmt("[LOG] %s", msg);
}

# 多返回值（通过 record 实现）
function divide(a: count, b: count): any {
    if (b == 0) {
        return [$ok = F, $error = "division by zero"];
    }
    return [$ok = T, $result = a / b];
}

# 函数作为一等公民
local f: function(count, count): count = add;
local result = f(3, 4);              # 7
```

### 6.2 闭包与高阶函数

```zeek
# 闭包：捕获外部变量
function make_counter(start: count): function(): count {
    local count = start;
    return function(): count {
        count = count + 1;
        return count;
    };
}

# 使用闭包
local counter = make_counter(0);
print counter();  # 1
print counter();  # 2
print counter();  # 3
```

---

## 7. 内置常量与函数

### 7.1 全局常量

```zeek
# 网络相关
UNKNOWN_ORIG | UNKNOWN_RESP    # 未知端点（0.0.0.0）
NULL_ADDRESS                    # 空地址
ANY_ADDR                        # 任意地址

# 日志相关
LOG_SUFFIX                      # 日志文件后缀
```

### 7.2 常用内置函数

```zeek
# 数学函数
local abs_val = abs(-42);           # 42
local sqrt_val = sqrt(16.0);        # 4.0
local rand_val = rand(100);         # [0, 100) 随机数
local srand_seed = srand(12345);    # 设置随机种子

# 字符串函数
local upper = to_upper("hello");    # "HELLO"
local lower = to_lower("HELLO");    # "hello"
local stripped = strip("  hi  ");  # "hi"
local replaced = gsub("hello", "l", "x");  # "hexxo"（全局替换）

# 类型检查
local is_str = is_string(x);       # T/F
local is_int = is_int(x);           # T/F
local is_vec = is_vector(x);        # T/F

# 序列化
local json_str = to_json(x);        # 转换为 JSON 字符串
```

---

## 8. Option 与 Directive

### 8.1 @ 指令（Directive）

```zeek
# 加载脚本
@load scripts/base/frameworks/intel

# 条件编译
@if (DEBUG_MODE)
    print "Debug mode enabled";
@endif

# 导入模块
@load-sigs etc/signature-file.sig

# 预处理宏
@define DEBUG
@ifdef DEBUG
    print "Debug enabled";
@endif
```

### 8.2 Option 变量

```zeek
# 在脚本中设置 zeekctl 选项
redef restrict_filters += [["not tcp", "not tcp"]];
redef site_files = ["local.zeek"];
```

---

## 9. 实战示例

### 9.1 连接信息统计

```zeek
# 连接统计 record
type ConnectionStats: record {
    orig: addr;
    resp: addr;
    bytes: count;
    packets: count;
    start_time: time;
};

# 全局连接表
global connections: table[addr, addr] of ConnectionStats;

# 事件处理程序
event connection_established(c: connection) {
    local orig = c$id$orig_h;
    local resp = c$id$resp_h;

    connections[orig, resp] = [
        $orig = orig,
        $resp = resp,
        $bytes = 0,
        $packets = 0,
        $start_time = c$start_time
    ];
}

event connection_state_remove(c: connection) {
    local orig = c$id$orig_h;
    local resp = c$id$resp_h;
    local key = (orig, resp);

    if (key in connections) {
        local stats = connections[key];
        print fmt("%s -> %s: %s bytes, %s pkts",
            stats$orig, stats$resp, stats$bytes, stats$packets);
        delete connections[key];
    }
}
```

### 9.2 DNS 查询监控

```zeek
# 监控可疑 DNS 查询
global suspicious_queries: set[string] = {
    "long-subdomain.example.com",
    "base64-encoded-query.xyz"
};

event dns_request(c: connection, msg: dns_msg, query: string, qtype: count) {
    # 检查是否为长子域名（可能的 DNS隧道）
    if (|query| > 100) {
        print fmt("Long DNS query: %s (%d chars)", query, |query|);
    }

    # 检查可疑域名
    if (query in suspicious_queries) {
        print fmt("Suspicious query: %s", query);
    }

    # 记录所有 DNS 查询
    print fmt("DNS: %s -> %s [%s]", c$id$orig_h, query,
        fmt_query_type(qtype));
}
```

---

## 10. 本章小结

本章介绍了 ZeekScript 的基础类型系统：

1. **基本类型**：bool、int、count、double、string、time、interval、addr、subnet、port
2. **复合类型**：record（结构体）、table（关联数组）、set（集合）、vector（动态数组）
3. **类型转换**：cat/strftime/to_addr/to_subnet 等转换函数
4. **操作符**：算术、比较、逻辑、位操作符完整支持
5. **变量作用域**：全局/局部/块级作用域，`::` 前缀访问全局
6. **函数**：支持闭包和高阶函数
7. **内置函数**：数学、字符串、类型检查、序列化等工具函数

**下一章**将深入讲解 Zeek 的**事件驱动模型**——事件（Event）的定义、注册、调度机制，以及如何编写自定义事件处理程序。

> [!tip] 延伸阅读
> - [ZeekScript Language Reference](https://docs.zeek.org/en/stable/script-reference/)
> - [Zeek Script Templates](https://docs.zeek.org/en/stable/examples/)
