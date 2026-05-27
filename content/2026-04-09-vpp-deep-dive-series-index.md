---
title: "VPP 深入探索系列索引"
date: 2026-04-09 20:00:00
tags: [vpp, fd.io, cisco, vector-packet-processing, series-index]
description: "VPP 深入探索系列文章索引，涵盖架构、协议、QoS、虚拟化、插件开发、性能调优与云原生"
pin: true
---

# VPP 深入探索系列索引

> [!abstract] 系列概述
> 本系列深入探讨 VPP (Vector Packet Processing)，从核心架构到云原生集成，共 42 章。

## 系列结构

| Part     | 主题               | 章节数  |
| -------- | ------------------ | ------- |
| **I**    | 基础架构与核心机制 | ch1-5   |
| **II**   | 数据平面协议       | ch6-10  |
| **III**  | 安全与 QoS         | ch11-15 |
| **IV**   | 虚拟化与容器集成   | ch16-20 |
| **V**    | 插件开发           | ch21-26 |
| **VI**   | 性能调优           | ch27-31 |
| **VII**  | 运维与部署         | ch32-36 |
| **VIII** | 云原生与前沿       | ch37-42 |

---

## Part I：基础架构与核心机制

| #   | 章节                                          | 主题                                          | 状态                                     |
| --- | --------------------------------------------- | --------------------------------------------- | ---------------------------------------- | --- |
| 1   | [[2026-04-09-vpp-deep-dive-scheduling         | VPP 深入探讨：调度器、Vector 处理与图重配置]] | Main loop、graph walk、vector processing | ✅  |
| 2   | [[2026-04-09-vpp-plugin-development-advanced  | VPP 插件开发：从入门到高级]]                  | Plugin 架构、API、CLI                    | ✅  |
| 3   | [[2026-04-09-vpp-advanced-features            | VPP 高级特性：QoS、ACL、癸酉技术与性能调优]]  | QoS、Policer、ACL                        | ✅  |
| 4   | [[2026-04-09-vpp-deep-dive-ch04-buffer-memory | VPP 深入探讨：Buffer 与 Memory 管理]]         | vlib_buffer、mempool、hugepage           | ✅  |
| 5   | [[2026-04-09-vpp-deep-dive-ch05-thread-model  | VPP 深入探讨：Thread 模型与 Worker]]          | Main vs workers、barrier 同步            | ✅  |

---

## Part II：数据平面协议

| #   | 章节                                                 | 主题                                    | 状态                         |
| --- | ---------------------------------------------------- | --------------------------------------- | ---------------------------- | --- |
| 6   | [[2026-04-09-vpp-deep-dive-ch06-bridge-domain        | VPP 深入探讨：L2 转发与 Bridge Domain]] | MAC 学习、VLAN、VXLAN        | ✅  |
| 7   | [[2026-04-09-vpp-deep-dive-ch07-ip-forwarding        | VPP 深入探讨：L3 转发与 IP Forwarding]] | 路由查找、FIB、ARP/NDP       | ✅  |
| 8   | [[2026-04-09-vpp-deep-dive-ch08-tunnel-encapsulation | VPP 深入探讨：隧道封装技术]]            | VXLAN/NVGRE/GENEVE、隧道端点 | ✅  |
| 9   | [[2026-04-09-vpp-deep-dive-ch09-mpls                 | VPP 深入探讨：MPLS 与 L2VPN]]           | 标签交换、VPLS、EVPN         | ✅  |
| 10  | [[2026-04-09-vpp-deep-dive-ch10-l4-processing        | VPP 深入探讨：L4 TCP/UDP 处理]]         | TCP stream、连接跟踪         | ✅  |

---

## Part III：安全与 QoS

| #   | 章节                                    | 主题                             | 状态                   |
| --- | --------------------------------------- | -------------------------------- | ---------------------- | --- |
| 11  | [[2026-04-09-vpp-deep-dive-ch11-acl     | VPP 深入探讨：ACL 架构与实现]]   | L2-L4 ACL、条目匹配    | ✅  |
| 12  | [[2026-04-09-vpp-deep-dive-ch12-policer | VPP 深入探讨：Policer 流量限制]] | 单速率三色、双速率三色 | ✅  |
| 13  | [[2026-04-09-vpp-deep-dive-ch13-qos     | VPP 深入探讨：QoS 队列与调度]]   | WFQ、SP、WRR           | ✅  |
| 14  | [[2026-04-09-vpp-deep-dive-ch14-shaper  | VPP 深入探讨：流量整形 Shaper]]  | 令牌桶、接口整形       | ✅  |
| 15  | [[2026-04-09-vpp-deep-dive-ch15-ipsec   | VPP 深入探讨：IPsec 加密]]       | IKEv2、crypto engine   | ✅  |

---

## Part IV：虚拟化与容器集成

| #   | 章节                                           | 主题                                 | 状态                     |
| --- | ---------------------------------------------- | ------------------------------------ | ------------------------ | --- |
| 16  | [[2026-04-09-vpp-deep-dive-ch16-vpp-kvm        | VPP 深入探讨：VPP + KVM/vhost-user]] | VM 连接、shared memory   | ✅  |
| 17  | [[2026-04-09-vpp-deep-dive-ch17-vpp-docker     | VPP 深入探讨：VPP + Docker/CNI]]     | CNI 插件、容器网络       | ✅  |
| 18  | [[2026-04-09-vpp-deep-dive-ch18-vpp-kubernetes | VPP 深入探讨：VPP + Kubernetes]]     | CNI、service mesh        | ✅  |
| 19  | [[2026-04-09-vpp-deep-dive-ch19-vpp-dpdk       | VPP 深入探讨：VPP + DPDK]]           | PMD、buffer 映射、零拷贝 | ✅  |
| 19.5 | [[2026-05-26-vpp-deep-dive-ch19a-memif|VPP 深入探讨：memif 内存接口]] | 共享内存、VPP-to-VPP、VPP-to-DPDK | ✅ |
| 20  | [[2026-04-09-vpp-deep-dive-ch20-vpp-openstack  | VPP 深入探讨：VPP + OpenStack]]      | ML2 驱动、Neutron 集成   | ✅  |

---

## Part V：Plugin 开发

| #   | 章节                                                | 主题                                  | 状态                             |
| --- | --------------------------------------------------- | ------------------------------------- | -------------------------------- | --- |
| 21  | [[2026-04-09-vpp-deep-dive-ch21-plugin-architecture | VPP 深入探讨：Plugin 架构与注册]]     | Plugin 注册、init hook、依赖管理 | ✅  |
| 22  | [[2026-04-09-vpp-deep-dive-ch22-binary-api          | VPP 深入探讨：API 定义与 Binary API]] | API 文件、消息生成、VAPI         | ✅  |
| 23  | [[2026-04-09-vpp-deep-dive-ch23-custom-node         | VPP 深入探讨：自定义 Node 开发]]      | Node 注册、dispatch、next node   | ✅  |
| 24  | [[2026-04-09-vpp-deep-dive-ch24-cli                 | VPP 深入探讨：CLI 命令开发]]          | 命令注册、参数解析、输出         | ✅  |
| 25  | [[2026-04-09-vpp-deep-dive-ch25-stats-telemetry     | VPP 深入探讨：统计与 Telemetry]]      | Counter、Histogram、API          | ✅  |
| 26  | [[2026-04-09-vpp-deep-dive-ch26-testing-debugging   | VPP 深入探讨：测试与调试]]            | 单元测试、集成测试、调试         | ✅  |

---

## Part VI：性能调优

| #   | 章节                                          | 主题                                  | 状态                 |
| --- | --------------------------------------------- | ------------------------------------- | -------------------- | --- |
| 27  | [[2026-04-16-vpp-deep-dive-ch27-profiling     | VPP 深入探讨：性能剖析工具]]          | trace、profile       | ✅  |
| 28  | [[2026-04-16-vpp-deep-dive-ch28-memory-tuning | VPP 深入探讨：Buffer 与 Memory 调优]] | heap、cache          | ✅  |
| 29  | [[2026-04-16-vpp-deep-dive-ch29-interrupt     | VPP 深入探讨：中断与轮询模式]]        | adaptive、coalescing | ✅  |
| 30  | [[2026-04-16-vpp-deep-dive-ch30-rss           | VPP 深入探讨：RSS 与多队列]]          | Receive Side Scaling | ✅  |
| 31  | [[2026-04-16-vpp-deep-dive-ch31-graph-tuning  | VPP 深入探讨：Graph 调优]]            | 热点检测             | ✅  |

---

## Part VII：运维与部署

| #   | 章节                                            | 主题                           | 状态                |
| --- | ----------------------------------------------- | ------------------------------ | ------------------- | --- |
| 32  | [[2026-04-09-vpp-deep-dive-ch32-startup         | VPP 深入探讨：启动配置]]       | startup.conf        | 🚧  |
| 33  | [[2026-04-09-vpp-deep-dive-ch33-debug           | VPP 深入探讨：日志与调试]]     | api trace、gdb      | 🚧  |
| 34  | [[2026-04-09-vpp-deep-dive-ch34-ha              | VPP 深入探讨：高可用与集群]]   | VRRP、故障切换      | 🚧  |
| 35  | [[2026-04-09-vpp-deep-dive-ch35-monitoring      | VPP 深入探讨：监控与告警]]     | prometheus、grafana | 🚧  |
| 36  | [[2026-04-09-vpp-deep-dive-ch36-troubleshooting | VPP 深入探讨：常见问题与排障]] | drop、leak          | 🚧  |

---

## Part VIII：云原生与前沿

|| # | 章节 | 主题 | 状态 |
||---|------|------|------|
|| 37 | [[2026-04-16-vpp-deep-dive-ch37-cnf-cloud-native|VPP 深入探讨：CNF 云原生网络功能]] | 微服务化架构、容器化部署、Service Mesh 集成 | ✅ |
|| 38 | [[2026-04-16-vpp-deep-dive-ch38-vpp-ebpf|VPP 深入探讨：VPP + eBPF 协同]] | XDP 集成、TC 流量控制、AF-XDP 零拷贝 | ✅ |
|| 39 | [[2026-04-16-vpp-deep-dive-ch39-p4-dataplane|VPP 深入探讨：P4 可编程数据面]] | P4 架构、P4Runtime 控制、STRONGMAN 模式 | ✅ |
|| 40 | [[2026-04-16-vpp-deep-dive-ch40-dpu-ipu|VPP 深入探讨：DPU/IPU 集成]] | DOCA 框架、BlueField、IPU、Stingray | ✅ |
|| 41 | [[2026-04-16-vpp-deep-dive-ch41-5g-upf|VPP 深入探讨：5G UPF 加速]] | 3GPP 架构、N3/N9/N6 接口、GTP-U、PFCP | ✅ |
|| 42 | [[2026-04-16-vpp-deep-dive-ch42-future|VPP 深入探讨：未来展望与路线图]] | FD.io 路线图、AI/ML、RISC-V、零信任 | ✅ |

---

## 更新历史

- 2026-04-09: 创建索引，完成 ch1-3 (基础架构与核心机制入门)
- 2026-04-09: 开始编写 ch4-ch5 (Buffer/Thread)

---

## 相关系列

- [[2026-04-09-dpdk-deep-dive-series-index|DPDK 深度探索系列]] - 兄弟系列，聚焦数据平面开发框架
- [[2026-04-09-ebpf-deep-dive-series-index|eBPF 深度探索系列]] - 内核可编程数据面
