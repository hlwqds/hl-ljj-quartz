---
title: "DPDK L2FWD Keepalive 示例分析与测试指南"
date: 2026-01-05 00:00:00
pin: true
tags: [dpdk, network, l2fwd, keepalive, timer]
---

> [!abstract] DPDK 高性能开发系列文章
> - [[2025-12-16-dpdk-open-euler-setup|环境搭建]]
> - [[2026-01-05-dpdk_portable_lab_guide|移动实验环境]]
> - [[2025-12-09-dpdk-mem|内存管理汇总]]
> - [[2025-12-16-dpdk-adjust-nb-rx-tx-desc|描述符调整]]
> - [[2025-12-16-dpdk-tx-offload-mbuf-fast-free|MBUF 快速释放]]
> - [[2025-12-31-dpdk_callbacks_guide|Callbacks 深度指南]]
> - [[2025-12-31-dpdk_mbuf_dynfield_register_guide|动态字段注册]]
> - [[2025-12-31-dpdk_kni_guide|KNI 深度指南]]
> - [[2025-12-31-dpdk_virtual_devices_guide|虚拟网卡指南]]
> - [[2026-01-04-dpdk_ip_fragmentation_guide|IP 分片]]
> - [[2026-01-04-ip_reassembly_analysis|IP 重组]]
> - [[2026-01-04-ipv4_multicast_guide|IPv4 组播]]
> - [[2026-01-04-软件流水线技术详解|软件流水线优化]]
> - [[2026-01-04-dpdk_flow_template_guide|Template API]]
> - [[2026-01-04-dpdk_flow_filtering_verification|流过滤验证]]
> - [[2026-01-05-l2fwd_keepalive_analysis|Keepalive 监控]]



# DPDK L2FWD Keepalive 示例分析与测试指南

本文档详细分析了 DPDK `examples/l2fwd-keepalive/main.c` 的代码逻辑，解释了 Keepalive（保活）机制与 Timer（定时器）的协作原理，并提供了测试方案。

## 1. 核心架构设计

`l2fwd-keepalive` 是标准二层转发（L2FWD）的增强版，增加了对数据面核心（Lcore）健康状态的监控功能。

### 1.1 设计思想
*   **监控者（Master Core）**：负责定期检查各个工作核心的时间戳。
*   **被监控者（Worker Cores）**：在处理业务的同时，定期更新自己的时间戳（盖章）。
*   **自愈能力**：如果监控者发现某个核心超时未响应，会判定其死亡并尝试重新启动该核心的任务。

### 1.2 关键数据结构
*   **`rte_global_keepalive_info`**：Keepalive 句柄，存储所有核心的状态。
*   **`rte_keepalive_shm`**：共享内存结构，用于将核心状态暴露给非 DPDK 的外部进程（如监控代理）。

---

## 2. Keepalive 与 Timer 协作机制详解

这部分逻辑是整个应用的核心。Timer 是“节拍器”，Keepalive 是“逻辑状态机”。

### 2.1 交互流程图 (ASCII)

```ascii
+-----------------------+              +------------------------+
|   Master Core (Main)  |              |   Worker Core (Lcore X)|
+-----------+-----------+              +------------+-----------+
            |                                       |
1. 创建 Keepalive 实例                              |
2. 注册 Dead Core 回调                              |
3. 注册 Relay Callback  <------------------[NEW]    | (用于同步状态给外部)
4. 注册 Worker Core X  -------------------------->  | (被加入监控列表)
            |                                       |
5. 设置 Timer (周期性)                              |
   (回调=dispatch_pings)                            |
            |                                       |
    [ Start Loop ] <------------------------+       |
            |                               |
6. rte_timer_manage()                       |
   (检查时间是否到期)                       |
            |                               |
      [ Timer 触发? ]                       |
            | YES                           |
            v                               |
   7. 执行检查回调:                         |
   rte_keepalive_dispatch_pings()           |
            |                               |
   [ 检查核心盖章时间 ]                     |
            |                               |
      > 阈值(失败)? ------------------------|-----> 8. rte_keepalive_mark_alive()
       /        \                           |       (Worker 循环盖章)
     YES         NO                         |       (更新 Last Alive 时间戳)
      |          |                          |
   判定 DEAD   判定 ALIVE                   |
      |          |                          |
   9. 触发 Relay Callback                   |
      (同步状态到共享内存 SHM)              |
      |                                     |
   10.触发 Dead 回调 (dead_core)            |
      尝试重启 Lcore X                      |
            |                               |
            +-------------------------------+       |
```

### 2.2 详细调用链分析

#### 阶段一：监控系统启动 (Master Core)
1.  **初始化 SHM**: `rte_keepalive_shm_create()` 创建共享内存，允许外部 Python 脚本监控。
2.  **创建实例**: `rte_keepalive_create(&dead_core, shm)`。
    *   这里绑定了核心死亡时的救护车函数：`dead_core`。
3.  **注册 Relay**: `rte_keepalive_register_relay_callback(..., relay_core_state, shm)`。
    *   这是内部状态通往外部世界的桥梁。
4.  **定时器绑定**: `rte_timer_reset()`。
    *   **周期**: `check_period` (例如 10ms)。
    *   **回调函数**: **`rte_keepalive_dispatch_pings`**。这是 DPDK 库内部提供的核心检查逻辑。

#### 阶段二：工人打卡 (Worker Core)
1.  **注册**: 在启动线程前，Master 调用 `rte_keepalive_register_core(..., lcore_id)`。
    *   这会在 Keepalive 内部的数组中标记该 lcore_id 为“受监控”。
2.  **打卡**: Worker 的 `while(1)` 循环第一行就是 `rte_keepalive_mark_alive()`。
    *   **底层实现**: 这是一个极其轻量的操作。它仅仅是读取当前 TSC (CPU 周期数)，然后原子写入到共享内存中的 `core_state[lcore_id].last_alive` 字段。

#### 阶段三：定期查岗与中继 (Master Core)
1.  Master 线程在 `while` 循环中调用 `rte_timer_manage()`。
2.  当 10ms 时间到，触发 `rte_keepalive_dispatch_pings()`。
3.  **核心检查逻辑**：
    *   遍历所有 Registered 的核心。
    *   计算 `delta = current_tsc - core_last_alive`。
4.  **Relay (中继) 逻辑**：
    *   在检查过程中，如果状态发生变化（或为了定期同步），库会调用用户注册的 **Relay Callback** (`relay_core_state`)。
    *   **实现**: `relay_core_state` 函数会调用 `rte_keepalive_relayed_state`，将当前的 `ALIVE/MISSING/DEAD` 状态写入到 **/dev/shm/** 下的共享内存文件中。
    *   **意义**: 这样外部的 Python 脚本或监控代理就能实时看到核心状态了。

#### 阶段四：死而复生 (Recovery)
1.  **判定 DEAD**: `delta` 超过致命阈值。
2.  **回调执行**: `dead_core` 函数被 Master 线程执行。
3.  **重启判断**: 代码检查该核心的状态 `rte_eal_get_lcore_state(id_core)`。
    *   如果是 `WAIT`（表示线程已经退出了，比如 break 出去了），则可以安全重启。
4.  **重启**: 调用 `rte_eal_remote_launch(l2fwd_launch_one_lcore, ..., id_core)`。
    *   这会重新在这个物理核心上创建一个新的执行上下文，重新进入 `l2fwd_main_loop`。

---

## 3. Demo 特有的“自杀”逻辑

为了演示监控有效性，代码中包含了一段随机触发线程退出的逻辑：
```c
/* 在 l2fwd_main_loop 中 */
uint64_t tsc_initial = rte_rdtsc();
uint64_t tsc_lifetime = rte_rand_max(8 * rte_get_tsc_hz()); // 随机 0-8 秒寿命

while (!terminate_signal_received) {
    rte_keepalive_mark_alive(...);
    
    // 如果运行时间超过随机寿命，直接退出循环（模拟死亡）
    if (check_period > 0 && cur_tsc - tsc_initial > tsc_lifetime)
        break; 
    
    // ... 正常转发逻辑 ...
}
```

---

## 4. 使用虚拟网卡 (`net_tap`) 测试验证

### 4.1 关键前提：核心数量要求 (Lcores)

**重要提示：此程序不支持单核心运行！**

*   **原因**：该程序设计为 **Master Core** 负责运行 Timer 和监控，**Worker Cores** 负责转发流量。
*   **如果使用 `-l 0` (单核)**：Master 核心只会进入 Timer 循环，`RTE_LCORE_FOREACH_WORKER` 循环将为空，导致转发线程根本不会启动，程序看起来像没有任何反应。
*   **要求**：**必须至少提供 2 个逻辑核心**（1 个 Master + N 个 Worker）。

### 4.2 运行命令
使用 `net_tap` 模拟两个端口，并开启 Keepalive 检测。

```bash
# -l 0,1: 核心 0 监控，核心 1 转发
# -K 10: 10ms 检查周期
# -T 1: 每秒打印一次统计
sudo ./build/l2fwd-keepalive -l 0,1 \
    --vdev=net_tap0,iface=dtap0 \
    --vdev=net_tap1,iface=dtap1 \
    -- \
    -p 0x3 -q 1 -K 10 -T 1
```

### 4.3 验证步骤
1.  **观察日志**：启动后 0-8 秒内，屏幕会打印 `Dead core 1 - restarting..`。
2.  **验证自愈**：看到日志后，统计数据（Port statistics）应继续刷新，证明核心 1 已成功复活。
3.  **外部监控 (验证 Relay)**：查看 `/dev/shm/` 目录，应存在 `rte_keepalive_shm_name` 文件。可以使用 `hexdump` 观察其中跳动的时间戳，这正是 Relay Callback 努力工作的证明。

## 5. 总结
`l2fwd-keepalive` 通过 **Timer（驱动）+ Keepalive（检测）+ Relay Callback（通知）+ Dead Callback（恢复）** 构成了一个完整的闭环监控系统。它是构建电信级高可用网络设备的基础组件之一。
