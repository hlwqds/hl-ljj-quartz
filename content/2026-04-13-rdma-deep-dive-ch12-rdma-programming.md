---
title: "RDMA 深度探索 (十二)：RDMA 编程起步"
date: 2026-04-13
tags: [rdma, series, rdma-core, libibverbs, rdma-cm, memory-registration, verbs]
description: "从零开始搭建 RDMA 开发环境，详解 rdma-core 用户态库、CM API 连接建立流程、内存注册机制，以及基础代码框架"
---

> [!info] RDMA 深度探索系列 0. [[2026-04-13-rdma-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-13-rdma-deep-dive-ch1-rdma-overview|第一章：RDMA 概述]]
> 2. [[2026-04-13-rdma-deep-dive-ch2-rdma-architecture|第二章：RDMA 架构]]
> 3. [[2026-04-13-rdma-deep-dive-ch3-infiniband|第三章：InfiniBand 架构]]
> 4. [[2026-04-13-rdma-deep-dive-ch4-roce|第四章：RoCE v1/v2]]
> 5. [[2026-04-13-rdma-deep-dive-ch5-iwarp|第五章：iWARP]]
> 6. [[2026-04-13-rdma-deep-dive-ch6-roce-vs-iwarp|第六章：RoCE vs iWARP 对比]]
> 7. [[2026-04-13-rdma-deep-dive-ch7-queue-pair|第七章：队列对 (QP)]]
> 8. [[2026-04-13-rdma-deep-dive-ch8-mr-pd|第八章：内存区域与保护域]]
> 9. [[2026-04-13-rdma-deep-dive-ch9-verbs-api|第九章：Verbs API]]
> 10. [[2026-04-13-rdma-deep-dive-ch10-ud-rc|第十章：UD vs RC 传输类型]]
> 11. [[2026-04-13-rdma-deep-dive-ch11-atomics|第十一章：RDMA 原子操作]]
> 12. **第十二章：RDMA 编程起步**

---

## 1. 开发环境搭建

### 1.1 依赖组件

RDMA 用户态编程依赖以下软件栈：

```
┌─────────────────────────────────────────────────────────────┐
│                    用户态应用程序                            │
├─────────────────────────────────────────────────────────────┤
│                    libibverbs (Verbs API)                   │
│                    librdmacm (RDMA CM)                       │
├─────────────────────────────────────────────────────────────┤
│                    rdma-core (用户态驱动)                   │
├─────────────────────────────────────────────────────────────┤
│                    OFED 驱动 (内核模块)                      │
│                    (mlx5_core, iw_cxgb4, etc.)              │
├─────────────────────────────────────────────────────────────┤
│                    HCA 硬件 (Mellanox, Intel, etc.)          │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 安装 rdma-core

```bash
# Debian/Ubuntu
sudo apt-get install rdma-core libibverbs-dev librdmacm-dev

# RHEL/CentOS
sudo yum install rdma-core libibverbs-devel librdmacm-devel

# 验证安装
$ rdma/devinfo
  hca_id: mlx5_0
    transport_type:    IB
    fw_ver:            20.XX.XXXX
    node_guid:         XXXX:XXXX:XXXX:XXXX
    sys_image_guid:    XXXX:XXXX:XXXX:XXXX
    vendor_id:         0x02c9
    vendor_part_id:    4099
    hw_ver:            0x0
    phys_port_cnt:     1
      port: 1
        state:          PORT_ACTIVE
        max_mtu:       4096 (5)
        active_mtu:    4096 (5)
        sm_lid:        1
        port_lid:      1
        link_layer:    IB
```

### 1.3 硬件检查

```bash
# 查看可用 RDMA 设备
$ ibv_devices
  device                 node_guid
  ───────────────────────  ───────────────────────
  mlx5_0                  XXXX:XXXX:XXXX:XXXX

# 查看设备详细信息
$ ibv_devinfo -d mlx5_0
  hca_type:              MT28908
  hca_vendor:            Mellanox
  hca_vendor_id:         0x02c9
  hca_capability_flags:  cksum_calc segv...
```

---

## 2. libibverbs 核心对象

### 2.1 对象关系图

RDMA 编程涉及的核心对象及其关系：

```
┌─────────────────────────────────────────────────────────────┐
│                      Context (ibv_context)                  │
│  代表一个 HCA 设备，通过它枚举和创建所有资源                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │ Protection      │  │ Completion      │                   │
│  │ Domain (PD)     │  │ Queue (CQ)      │                   │
│  │                 │  │                 │                   │
│  │ - QP            │  │ - WC 事件        │                   │
│  │ - MR            │  │ - 轮询模式       │                   │
│  │ - MW            │  │                 │                   │
│  └─────────────────┘  └─────────────────┘                   │
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │ Queue Pair (QP) │  │ Memory Region   │                   │
│  │                 │  │ (MR)            │                   │
│  │ - Send Queue    │  │                 │                   │
│  │ - Recv Queue    │  │ - lkey/rkey     │                   │
│  │ - QP Number     │  │ - DMA 映射      │                   │
│  └─────────────────┘  └─────────────────┘                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 获取 Context

```c
#include <infiniband/verbs.h>
#include <rdma/rdma_cma.h>

int main(int argc, char *argv[]) {
    struct ibv_context *ctx = NULL;
    struct ibv_device **device_list;
    int num_devices;

    // 1. 获取设备列表
    device_list = ibv_get_device_list(&num_devices);
    if (!device_list || num_devices == 0) {
        fprintf(stderr, "No RDMA devices found\n");
        return -1;
    }

    // 2. 打开第一个设备
    ctx = ibv_open_device(device_list[0]);
    if (!ctx) {
        fprintf(stderr, "Failed to open device\n");
        return -1;
    }

    printf("Opened device: %s\n", ibv_get_device_name(device_list[0]));

    // 3. 查询设备能力
    struct ibv_device_attr device_attr;
    ibv_query_device(ctx, &device_attr);
    printf("Max QP: %d, Max MR: %ld\n",
           device_attr.max_qp, device_attr.max_mr);

    // 4. 清理
    ibv_close_device(ctx);
    ibv_free_device_list(device_list);

    return 0;
}
```

---

## 3. RDMA CM 连接建立

### 3.1 CM vs Verbs 直接创建

RDMA 有两种连接建立方式：

```
┌─────────────────────────────────────────────────────────────┐
│                    方式一：RDMA CM (推荐)                    │
│                                                             │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐             │
│  │ rdma_cm  │───►│ 创建 QP  │───►│ 建立连接 │             │
│  │ 事件驱动 │    │ (CM ID)  │    │ RTS 状态 │             │
│  └──────────┘    └──────────┘    └──────────┘             │
│                                                             │
│  优点：与 socket API 类似，易于理解                          │
│  缺点：多一次用户态→内核交互                                │
├─────────────────────────────────────────────────────────────┤
│                    方式二：libibverbs 直接创建               │
│                                                             │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────┐ │
│  │ 创建 PD  │───►│ 创建 QP  │───►│ 修改 QP  │───►│ 交换 │ │
│  │          │    │          │    │ 状态机   │    │ 地址 │ │
│  └──────────┘    └──────────┘    └──────────┘    └──────┘ │
│                                                             │
│  优点：更底层，控制更精细                                    │
│  缺点：需要自己处理地址交换                                  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 RDMA CM 服务器端

```c
#include <rdma/rdma_cma.h>

struct rdma_event_channel *ec = NULL;
struct rdma_cm_id *listener_id = NULL;
struct rdma_cm_id *conn_id = NULL;
struct sockaddr_in addr;

int setup_server() {
    // 1. 创建事件通道
    ec = rdma_create_event_channel();
    if (!ec) return -1;

    // 2. 创建 RDMA CM ID (监听)
    if (rdma_create_id(ec, &listener_id, NULL, RDMA_PS_TCP)) {
        return -1;
    }

    // 3. 绑定地址和端口
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(20079);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (rdma_bind_addr(listener_id, (struct sockaddr *)&addr)) {
        return -1;
    }

    // 4. 监听连接请求
    if (rdma_listen(listener_id, 10)) {
        return -1;
    }

    printf("Server listening on port 20079\n");
    return 0;
}

// 事件处理循环
int event_loop() {
    struct rdma_cm_event *event = NULL;

    while (1) {
        // 等待 CM 事件
        if (rdma_get_cm_event(ec, &event)) {
            continue;
        }

        enum rdma_cm_event_type type = event->id->event;
        struct rdma_cm_id *id = event->id;

        switch (type) {
        case RDMA_CM_EVENT_CONNECT_REQUEST:
            // 收到连接请求
            printf("Connect request received\n");
            handle_connect_request(id, event->param.conn.private_data);
            rdma_ack_cm_event(event);
            break;

        case RDMA_CM_EVENT_ESTABLISHED:
            // 连接建立完成
            printf("Connection established\n");
            rdma_ack_cm_event(event);
            break;

        case RDMA_CM_EVENT_DISCONNECTED:
            // 对端断开
            printf("Disconnected\n");
            rdma_disconnect(id);
            rdma_ack_cm_event(event);
            break;

        default:
            rdma_ack_cm_event(event);
            break;
        }
    }
}
```

### 3.3 RDMA CM 客户端

```c
int setup_client() {
    struct rdma_event_channel *ec = NULL;
    struct rdma_cm_id *conn_id = NULL;
    struct sockaddr_in addr;

    // 1. 创建事件通道和 CM ID
    ec = rdma_create_event_channel();
    rdma_create_id(ec, &conn_id, NULL, RDMA_PS_TCP);

    // 2. 解析目标地址
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(20079);
    inet_pton(AF_INET, "192.168.1.100", &addr.sin_addr);

    // 3. 解析路由 (确定如何到达目标)
    if (rdma_resolve_addr(conn_id, NULL, (struct sockaddr *)&addr, 2000)) {
        fprintf(stderr, "Failed to resolve address\n");
        return -1;
    }

    // 4. 等待 RDMA_CM_EVENT_ADDR_RESOLVED 事件
    // 然后等待 RDMA_CM_EVENT_ROUTE_RESOLVED

    // 5. 发起连接
    struct rdma_conn_param conn_param = {
        .initiator_depth = 16,
        .responder_resources = 16,
        .retry_count = 5,
    };

    if (rdma_connect(conn_id, &conn_param)) {
        return -1;
    }

    return 0;
}
```

---

## 4. 内存注册 (Memory Registration)

### 4.1 为什么需要内存注册

RDMA 访问的内存必须事先"注册"，原因是：

```
┌─────────────────────────────────────────────────────────────┐
│                  内存注册的作用                              │
│                                                             │
│  1. 虚拟地址 → 物理地址转换                                  │
│     应用程序使用虚拟地址，HCA DMA 需要物理地址               │
│     注册过程建立虚拟页到物理页的映射表                        │
│                                                             │
│  2. 内存权限控制                                             │
│     指定内存区域是只读还是可写                                │
│     lkey/rkey 控制访问权限                                   │
│                                                             │
│  3. 锁定物理页                                               │
│     防止内存被 swap out 或 移动                              │
│     保证 DMA 始终能找到正确的物理页                          │
│                                                             │
│  4. 缓存对齐                                                 │
│     HCA 内部 TLB 缓存条目对齐要求                            │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 注册内存区域

```c
#include <infiniband/verbs.h>

struct ibv_mr *register_memory(void *buf, size_t size, struct ibv_pd *pd) {
    // 注册内存
    struct ibv_mr *mr = ibv_reg_mr(pd,          // Protection Domain
                                   buf,          // 虚拟地址
                                   size,         // 大小
                                   IBV_ACCESS_LOCAL_WRITE |  // 本地写
                                   IBV_ACCESS_REMOTE_READ |  // 远端读
                                   IBV_ACCESS_REMOTE_WRITE); // 远端写

    if (!mr) {
        fprintf(stderr, "Memory registration failed\n");
        return NULL;
    }

    printf("Registered memory at %p, size %zu\n", buf, size);
    printf("  lkey: 0x%x\n", mr->lkey);
    printf("  rkey: 0x%x\n", mr->rkey);

    return mr;
}

// 完整示例
int main() {
    // 1. 分配内存 (对齐到页面边界)
    const int BUF_SIZE = 4096;
    void *buf = aligned_alloc(sysconf(_SC_PAGESIZE), BUF_SIZE);
    memset(buf, 0, BUF_SIZE);

    // 2. 创建 Protection Domain
    struct ibv_pd *pd = ibv_alloc_pd(ctx);

    // 3. 注册内存
    struct ibv_mr *mr = register_memory(buf, BUF_SIZE, pd);

    // 4. 使用 lkey/rkey 进行 RDMA 操作...

    // 5. 注销内存
    ibv_dereg_mr(mr);
    free(buf);

    return 0;
}
```

### 4.3 内存注册标志

| 标志                      | 说明                 | 使用场景                     |
| ------------------------- | -------------------- | ---------------------------- |
| `IBV_ACCESS_LOCAL_WRITE`  | 本地可写             | 本地写入 buffer              |
| `IBV_ACCESS_REMOTE_WRITE` | 远端可写             | 允许对方 RDMA Write 到此区域 |
| `IBV_ACCESS_REMOTE_READ`  | 远端可读             | 允许对方 RDMA Read 此区域    |
| `IBV_ACCESS_MW_BIND`      | 可绑定 Memory Window | 使用 MW 时需要               |
| `IBV_ACCESS_ZERO_BASED`   | 零基础地址注册       | 简化地址计算                 |

---

## 5. 完整初始化流程

### 5.1 服务器初始化序列

```
┌─────────────────────────────────────────────────────────────┐
│                   服务器端初始化流程                          │
│                                                             │
│  1. ibv_get_device_list()      获取设备列表                  │
│           │                                               │
│           ▼                                               │
│  2. ibv_open_device()          打开 HCA                     │
│           │                                               │
│           ▼                                               │
│  3. ibv_alloc_pd()             分配 Protection Domain      │
│           │                                               │
│           ▼                                               │
│  4. ibv_create_cq()            创建 Completion Queue        │
│           │                                               │
│           ▼                                               │
│  5. ibv_create_qp()            创建 Queue Pair              │
│           │                                               │
│           ▼                                               │
│  6. rdma_create_id()           创建 CM ID (RDMA CM)         │
│           │                                               │
│           ▼                                               │
│  7. rdma_bind_addr()           绑定地址                     │
│           │                                               │
│           ▼                                               │
│  8. rdma_listen()              开始监听                     │
│           │                                               │
│           ▼                                               │
│  9. 事件循环:                                              │
│     - CONNECT_REQUEST → 接受/拒绝                           │
│     - ESTABLISHED → 开始收发数据                           │
│     - DISCONNECTED → 清理                                 │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 代码框架

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <infiniband/verbs.h>
#include <rdma/rdma_cma.h>

#define BUF_SIZE 4096

// 全局资源
struct context {
    struct ibv_context *verbs_ctx;
    struct ibv_pd *pd;
    struct ibv_cq *cq;
    struct ibv_qp *qp;
    struct ibv_mr *mr;
    void *buf;

    struct rdma_event_channel *ec;
    struct rdma_cm_id *listener;
};

struct context ctx;

int create_qp() {
    // 创建 QP
    struct ibv_qp_init_attr qp_attr = {
        .send_cq = ctx.cq,
        .recv_cq = ctx.cq,
        .cap = {
            .max_send_wr = 128,
            .max_recv_wr = 128,
            .max_send_sge = 16,
            .max_recv_sge = 16,
        },
        .qp_type = IBV_QPT_RC,
    };

    ctx.qp = ibv_create_qp(ctx.pd, &qp_attr);
    if (!ctx.qp) {
        fprintf(stderr, "Failed to create QP\n");
        return -1;
    }

    return 0;
}

int server_init() {
    // 1. 打开设备
    struct ibv_device **list = ibv_get_device_list(NULL);
    if (!list) return -1;
    ctx.verbs_ctx = ibv_open_device(list[0]);
    ibv_free_device_list(list);
    if (!ctx.verbs_ctx) return -1;

    // 2. 分配 PD
    ctx.pd = ibv_alloc_pd(ctx.verbs_ctx);
    if (!ctx.pd) return -1;

    // 3. 创建 CQ
    ctx.cq = ibv_create_cq(ctx.verbs_ctx, 256, NULL, NULL, 0);
    if (!ctx.cq) return -1;

    // 4. 创建 QP
    if (create_qp()) return -1;

    // 5. 分配并注册内存
    ctx.buf = aligned_alloc(sysconf(_SC_PAGESIZE), BUF_SIZE);
    ctx.mr = ibv_reg_mr(ctx.pd, ctx.buf, BUF_SIZE,
                        IBV_ACCESS_LOCAL_WRITE |
                        IBV_ACCESS_REMOTE_WRITE |
                        IBV_ACCESS_REMOTE_READ);
    if (!ctx.mr) return -1;

    // 6. RDMA CM 设置
    ctx.ec = rdma_create_event_channel();
    rdma_create_id(ctx.ec, &ctx.listener, NULL, RDMA_PS_TCP);

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(20079),
        .sin_addr.s_addr = INADDR_ANY,
    };

    rdma_bind_addr(ctx.listener, (struct sockaddr *)&addr);
    rdma_listen(ctx.listener, 10);

    printf("Server initialized, listening on port 20079\n");
    return 0;
}
```

---

## 6. 地址交换

### 6.1 需要交换什么

RDMA 连接建立后，双方需要交换以下信息才能进行 RDMA 操作：

```c
// 本地端需要告知远端的信息
struct connection_info {
    uint32_t qp_num;        // QP 编号 (远端需要知道发到哪个 QP)
    uint32_t lkey;          // 本地 MR 的 lkey (本地 RDMA Read 时)
    uint32_t rkey;          // 远端 MR 的 rkey (远端 RDMA Write 时)
    uint64_t buf_addr;      // Buffer 虚拟地址 (仅用于调试，实际 RDMA 不依赖本端地址)
    uint64_t buf_raddr;     // 远端 buffer 地址 (RDMA 操作目标)
};
```

### 6.2 通过 private_data 交换

RDMA CM 允许在连接建立时附加 private_data：

```c
// 服务器接受连接时附加信息
struct conn_data {
    uint32_t qp_num;
    uint32_t rkey;
    uint64_t buf_addr;
};

int accept_connection(struct rdma_cm_id *id) {
    struct conn_data my_data = {
        .qp_num = ctx.qp->qp_num,
        .rkey = ctx.mr->rkey,
        .buf_addr = (uint64_t)ctx.buf,
    };

    struct rdma_conn_param conn_param = {
        .private_data = &my_data,
        .private_data_len = sizeof(my_data),
        .responder_resources = 16,
        .initiator_depth = 16,
    };

    return rdma_accept(id, &conn_param);
}

// 客户端处理连接响应
void on_connect_request(struct rdma_cm_id *id) {
    struct conn_data *peer_data = event->param.conn.private_data;

    // 将对端 buffer 信息存储在 id->context 中
    // 后续 RDMA 操作使用 peer_data->buf_addr 和 peer_data->rkey
}
```

---

## 7. 编译与运行

### 7.1 编译

```makefile
# Makefile
CFLAGS += -Wall -O2 -g
LDFLAGS += -libverbs -lrdmacm -lpthread

target: client server

client: client.o
	gcc $(CFLAGS) -o $@ $^ $(LDFLAGS)

server: server.o
	gcc $(CFLAGS) -o $@ $^ $(LDFLAGS)

%.o: %.c
	gcc $(CFLAGS) -c -o $@ $<
```

```bash
# 编译
gcc -o server server.c -libverbs -lrdmacm -lpthread
gcc -o client client.c -libverbs -lrdmacm -lpthread
```

### 7.2 运行时检查

```bash
# 检查 RDMA 设备状态
ibv_devinfo

# 查看端口状态
ibstat mlx5_0

# 运行应用
./server &
./client 192.168.1.100

# 用 tcpdump 或 ibdump 抓包验证
ibdump -d mlx5_0 -i 1
```

---

## 8. 常见问题

**Q: ibv_open_device 返回 NULL？**
A: 检查：1) RDMA 驱动是否加载 `lsmod | grep mlx5`；2) 设备是否被其他进程占用；3) 权限问题 `sudo ./app`。

**Q: ibv_reg_mr 失败？**
A: 可能原因：1) 内存未对齐（需页对齐）；2) PD 已达上限；3) 内存已被注册过；4) 传入大小为 0。

**Q: rdma_resolve_addr 超时？**
A: 检查网络连通性、PFC 流控配置、GID 是否正确生成。

**Q: 连接建立后无法通信？**
A: 检查 QP 状态机是否正确转换到 RTS，以及 lkey/rkey 是否正确交换。

**Q: 如何选择 RDMA CM 还是直接使用 Verbs？**
A: 推荐 RDMA CM，它封装了地址解析和路由发现流程，代码更简洁。直接使用 Verbs 适合已有 socket 代码需要迁移的场景。
