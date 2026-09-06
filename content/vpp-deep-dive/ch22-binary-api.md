---
title: "VPP 深入探讨 ch22：API 定义与 Binary API"
date: 2026-04-10 05:00:00
tags: [vpp, api, binary-api, vapi, rpc, message, swinterface]
description: "深入解析 VPP Binary API：API 文件格式、消息定义、代码生成、VAPI 客户端、API追踪与调试"
---

# VPP 深入探讨 ch22：API 定义与 Binary API

> [!abstract] 核心要点
> VPP 使用 Binary API 进行进程间通信。本章深入解析 API 文件格式、消息定义、代码生成、VAPI 客户端与 API 追踪。

## 1. Binary API 概述

### 1.1 API 通信

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP Binary API                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP Main Process                         │  │
│  │  - CLI (Unix Socket)                                 │  │
│  │  - API (Binary Socket)                               │  │
│  │  - Stats (Shared Memory)                             │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↑                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              API Client                               │  │
│  │  - Go/Python/C Client                                │  │
│  │  - VPP CLI                                           │  │
│  │  - gRPC Bridge                                       │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Socket API

```bash
# VPP API Socket
ls -la /run/vpp/

# 示例：
# srw-rw-- 1 root root   0 Apr 10  /run/vpp/api.sock
# srw-rw-- 1 root root   0 Apr 10  /run/vpp/stats.sock

# API socket 类型
# - binary API: /run/vpp/api.sock (swig 管理)
# - CLI: /run/vpp/cli.sock
```

## 2. API 定义文件

### 2.1 .api 文件格式

```api
/* my_plugin.api */

/* Section markers */
define my_plugin_hello {
    /* Message ID (自动生成) */
    u32 client_index;
    u32 context;

    /* Parameters */
    u32 plugin_id;
    u8 name[64];
};

define my_plugin_hello_reply {
    u32 context;
    i32 retval;
    u32 plugin_id;
    u8 name[64];
};

/* 带有 handle 的消息 */
define my_plugin_object_create {
    u32 client_index;
    u32 context;

    /* Autoreply */
    u64 object_handle;
};

define my_plugin_object_delete {
    u32 client_index;
    u32 context;

    u64 object_handle;
};

define my_plugin_object_details {
    u32 context;
    u64 object_handle;
    u32 flags;
};

/* Events (VPP → Client) */
define my_plugin_event {
    u32 context;
    u64 object_handle;
    u32 event_type;
};
```

### 2.2 类型定义

```api
/* 基础类型 */
u8, u16, u32, u64
i8, i16, i32, i64
f64

/* 数组 */
u8 name[64];

/* 可选字段 */
u64 optional_handle[1];
u32 optional_value;

/* 手动设置 */
manual_print both
manual_validate both
manual_endian both
```

### 2.3 服务定义

```api
service my_plugin_hello_service {
    my_plugin_hello_reply
        stream my_plugin_event;
};
```

## 3. 代码生成

### 3.1 生成器

```bash
# 生成 API 代码
cd build
python3 ../src/tools/vppapigen/gen.py \
    --input-dir ../src/plugins/my_plugin/ \
    --output-dir ./my_plugin/

# 生成文件：
# - my_plugin.api.h (消息定义)
# - my_plugin.api.c (序列化/反序列化)
# - my_plugin.go (Go 客户端)
# - my_plugin.py (Python 客户端)
```

### 3.2 生成的头文件

```c
/* my_plugin.api.h (自动生成) */

#ifndef included_my_plugin_api_h
#define included_my_plugin_api_h

#include <vapi/api_h.api.h>  // 基础类型

/* Message IDs */
#define MY_PLUGIN_HELLO_ID 1
#define MY_PLUGIN_HELLO_REPLY_ID 2

/* Message structures */
typedef struct __attribute__ ((packed)) {
    u32 client_index;
    u32 context;
    u32 plugin_id;
    u8 name[64];
}) my_plugin_hello_t;

typedef struct __attribute__ ((packed)) {
    u32 context;
    i32 retval;
    u32 plugin_id;
    u8 name[64];
}) my_plugin_hello_reply_t;

/* 函数声明 */
void
vl_my_plugin_hello_t_print(
    const vl_api_my_plugin_hello_t *m,
    FILE *f);

#endif /* included_my_plugin_api_h */
```

## 4. VAPI 客户端

### 4.1 C 客户端

```c
// my_plugin_test.c
#include <vapi/vapi.h>

int
main(int argc, char *argv[])
{
    vapi_main_t vam = {0};
    vapi_main_init(&vam);

    // 连接 VPP
    if (vapi_connect(&vam) != 0) {
        fprintf(stderr, "Failed to connect\n");
        return 1;
    }

    // 发送消息
    vl_api_my_plugin_hello_t msg = {
        .client_index = vam->my_client_index,
        .context = 1,
        .plugin_id = 42,
    };
    memcpy(msg.name, "test", 4);

    // 发送并等待回复
    vapi_msg_my_plugin_hello_reply_t *reply;
    vapi_lock(&vam);
    vapi_send(&vam, (char *)&msg, sizeof(msg));
    reply = vapi_recv_reply(&vam);
    vapi_unlock(&vam);

    if (reply) {
        printf("Reply: retval=%d\n", reply->retval);
        vapi_msg_free(&vam, (char *)reply);
    }

    vapi_disconnect(&vam);
    return 0;
}
```

### 4.2 Python 客户端

```python
# my_plugin_client.py
from vpp_papi import VPP

# 连接 VPP
vpp = VPP("/run/vpp/api.sock")

# 发送消息
msg = {
    "client_index": 0,
    "context": 1,
    "plugin_id": 42,
    "name": b"test\x00" * 16,
}

# 同步调用
reply = vpp.api.my_plugin_hello(msg)

print(f"Reply: {reply}")

# 异步调用 + 事件处理
def handle_event(event):
    print(f"Event: {event}")

vpp.api.my_plugin_hello_async(msg, callback=handle_event)
vpp.dispatch()  # 处理事件
```

## 5. API 追踪

### 5.1 API Trace

```bash
# 启用 API 追踪
vpp# api trace save api.trace

# 运行一些命令
vpp# show interface

# 停止追踪
vpp# api trace dump api.trace

# 读取追踪
vpp# show api trace
```

### 5.2 API 调试

```bash
# 显示 API 统计
vpp# show api statistics

# 示例输出：
# Binary API calls: 12345
# RPC calls: 6789
# Replies: 12345
# Errors: 0

# API message details
vpp# show api message my_plugin_hello

# 示例：
# Name: my_plugin_hello
# Size: 80 bytes
# Fields:
#   client_index: u32
#   context: u32
#   plugin_id: u32
#   name: u8[64]
```

## 6. 自定义 API

### 6.1 API 消息处理

```c
// my_plugin_api.c

// 消息处理函数
static void
vl_api_my_plugin_hello_t_handler(
    const vl_api_my_plugin_hello_t *mp)
{
    my_plugin_main_t *pm = &my_plugin_main;

    // 检查客户端
    if (!pm->validate_client(mp->client_index)) {
        send_error_reply(mp->client_index, mp->context, -1);
        return;
    }

    // 处理消息
    int retval = my_plugin_process_hello(mp->plugin_id, mp->name);

    // 发送回复
    vl_api_my_plugin_hello_reply_t *rp = NULL;
    rp = vl_msg_api_alloc(sizeof(*rp));
    rp->_vl_msg_id = MY_PLUGIN_HELLO_REPLY_ID;
    rp->context = mp->context;
    rp->retval = retval;
    rp->plugin_id = pm->my_plugin_id;

    vl_msg_api_send(to_vpp, (u8 *)rp);
}
```

### 6.2 消息注册

```c
// API 消息表
#include <vapi/api.api.h>

// 消息表
static vl_msg_api_msg_t my_plugin_api_msg_table[] = {
#define _(id,n,c) { #n, vl_api_ ## n ## _t_handler },
    foreach_api_message
#undef _
};

// 初始化 API
static clib_error_t *
my_plugin_api_init(vlib_main_t *vm)
{
    // 注册消息处理函数
    for (int i = 0; i < ARRAY_LEN(my_plugin_api_msg_table); i++) {
        vl_msg_api_register(
            vm,
            my_plugin_api_msg_table[i].name,
            my_plugin_api_msg_table[i].handler);
    }

    return NULL;
}
```

## 7. gRPC Bridge

### 7.1 gRPC 配置

```bash
# 启用 gRPC
vpp# set grpc port 50051
vpp# set grpc enable

# gRPC 服务端口
# 默认：localhost:50051
```

### 7.2 gRPC Proto

```protobuf
// vpp.proto
syntax = "proto3";

package vpp;

service VPP {
    // Binary API 映射到 gRPC
    rpc Send (BinaryApiMessage) returns (BinaryApiMessage);
    rpc SendStream (stream BinaryApiMessage) returns (stream BinaryApiMessage);
}

message BinaryApiMessage {
    bytes data = 1;
}
```

## 8. 总结

Binary API 流程：

```
┌─────────────────────────────────────────────────────────────┐
│                    API 调用流程                              │
│                                                              │
│  Client                                                     │
│    ↓                                                        │
│  1. 构造 vl_api_xxx_t 结构                                  │
│    ↓                                                        │
│  2. vl_msg_api_send()                                      │
│    ↓                                                        │
│  Socket (/run/vpp/api.sock)                                 │
│    ↓                                                        │
│  3. VPP 接收消息                                            │
│    ↓                                                        │
│  4. vl_api_xxx_t_handler()                                 │
│    ↓                                                        │
│  5. 发送回复                                                │
│    ↓                                                        │
│  Client 收到回复                                            │
└─────────────────────────────────────────────────────────────┘
```

API 文件编译：

```
my_plugin.api
    ↓ vppapigen
my_plugin.api.h  (消息定义)
my_plugin.api.c  (序列化)
my_plugin.go     (Go 客户端)
my_plugin.py     (Python 客户端)
```

---

## 参考资源

- [VPP API 文档](https://wiki.fd.io/view/VPP/API_Plug-In_Architecture)
- [VPP API Types](https://wiki.fd.io/view/VPP/API_message_types)
- [gRPC VPP](https://wiki.fd.io/view/VPP/GRPC)
