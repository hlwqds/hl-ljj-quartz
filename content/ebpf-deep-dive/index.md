---
title: "eBPF 2026 深度探索系列索引"
date: 2026-04-08
pin: true
description: "eBPF 深度探索全系列 43 篇文章的完整索引，涵盖从寄存器到生态全景的系统化学习路径"
tags:
  - ebpf
  - series
  - index
---

# eBPF 2026 深度探索系列

> [!tip] 系列说明
> 本系列共 43 篇文章，从 eBPF 底层指令集出发，经过网络、安全、可观测性、AI 等核心领域，最终抵达跨平台、硬件卸载和生态全景。适合有一定 Linux 内核基础的开发者系统性进阶。
>
> 标记 🚧 的章节内容尚待补全，后续会持续更新。

---

## Part I：核心基础 (Fundamentals)

从零理解 eBPF 的运行机制——寄存器、指令集、验证器、Map 和 BTF。

| #   | 章节                                       | 主题                                               | 状态 |
| --- | ------------------------------------------ | -------------------------------------------------- | ---- |
| 1   | [[ch1-registers-and-instructions\|第一章]] | 寄存器、指令集与核心限制                           | ✅   |
| 1.5 | [[ch1-5-function-calls\|第一.五章]]        | 四种函数调用机制 (helpers/kfunc/bpf2bpf/tail call) | ✅   |
| 1.6 | [[ch1-6-the-verifier\|第一.六章]]          | 验证器 (Verifier) 的底层逻辑                       | ✅   |
| 2   | [[ch2-maps-and-communication\|第二章]]     | Map 机制与跨空间通信                               | ✅   |
| 2.5 | [[ch2-5-kptr-and-ownership\|第二.五章]]    | kptr (内核指针) 与内存所有权模型                   | ✅   |
| 3   | [[ch3-core-and-btf\|第三章]]               | CO-RE 与 BTF 的跨版本魔法                          | ✅   |

---

## Part II：追踪与安全 (Tracing & Security)

掌握 eBPF 的挂载体系：从 kprobe/uprobe 到 LSM 安全执法。

| #   | 章节                                         | 主题                              | 状态 |
| --- | -------------------------------------------- | --------------------------------- | ---- |
| 4   | [[ch4-tracing-hooks-and-security\|第四章]]   | 从 kprobe 到 LSM 的追踪全图景     | ✅   |
| 7   | [[ch7-security-lsm-enforcement\|第七章]]     | LSM BPF 从可观测到安全执法        | ✅   |
| 7.5 | [[ch7-5-uprobes-dynamic-tracing\|第七.五章]] | uprobe 用户态动态追踪原理         | ✅   |
| 7.6 | [[ch7-6-bpftime-user-runtime\|第七.六章]]    | bpftime 与用户态 eBPF 加速        | ✅   |
| 7.8 | [[ch7-8-uprobe-selection-guide\|第七.八章]]  | uprobe 选型指南：内核态 vs 用户态 | ✅   |
| 13  | [[ch13-usdt-tracing\|第十三章]]              | USDT 用户态静态定义追踪           | ✅   |

---

## Part III：网络与流量 (Networking)

eBPF 的性能杀手锏——XDP、TC、AF_XDP 及高级网络应用。

| #    | 章节                                                                     | 主题                              | 状态 |
| ---- | ------------------------------------------------------------------------ | --------------------------------- | ---- |
| 5    | [[ch5-xdp-networking-performance\|第五章]]                               | XDP 极致网络性能与全栈架构        | ✅   |
| 6    | [[ch6-tc-traffic-control\|第六章]]                                       | TC (Traffic Control) 流量调度艺术 | ✅   |
| 9    | [[ch9-af-xdp-zero-copy\|第九章]]                                         | AF_XDP 零拷贝与用户态协议栈       | ✅   |
| 29   | [[ch29-networking-deep-dive\|第二十九章]]                                | 负载均衡、Sockmap 与拥塞控制      | ✅   |
| 29.5 | [[2026-05-26-ebpf-deep-dive-netkit-container-networking\|第二十九.五章]] | netkit、veth 与容器网络加速       | ✅   |

---

## Part IV：系统与调度 (System & Scheduling)

深入操作系统内核——调度器、迭代器、容器隔离与存储加速。

| #   | 章节                                        | 主题                         | 状态 |
| --- | ------------------------------------------- | ---------------------------- | ---- |
| 10  | [[ch10-sched-ext-custom-scheduler\|第十章]] | sched_ext 自定义 CPU 调度器  | ✅   |
| 11  | [[ch11-bpf-iterators\|第十一章]]            | BPF Iterators 内核对象迭代器 | ✅   |
| 15  | [[ch15-container-isolation\|第十五章]]      | 无感增强容器隔离性           | ✅   |
| 17  | [[ch17-storage-and-filesystem\|第十七章]]   | 存储与文件系统加速           | ✅   |
| 20  | [[ch20-edge-iot-acceleration\|第二十章]]    | 边缘计算与工业协议加速       | ✅   |

---

## Part V：工程化实践 (Engineering)

从开发到生产的完整工程链路——调试、测试、CI/CD、生命周期管理和热升级。

| #   | 章节                                              | 主题                             | 状态 |
| --- | ------------------------------------------------- | -------------------------------- | ---- |
| 8   | [[ch8-advanced-tuning-and-profiling\|第八章]]     | 进阶实战与内核调优               | ✅   |
| 12  | [[ch12-kfuncs-evolution\|第十二章]]               | kfuncs 下一代内核交互标准        | ✅   |
| 18  | [[ch18-lifecycle-and-links\|第十八章]]            | 生命周期管理与 BPF Links         | ✅   |
| 18  | [[ch18-bpftime-injection-mastery\|第十八章(续)]]  | bpftime 自动化注入与全量监控实战 | ✅   |
| 19  | [[ch19-atomic-updates-and-hot-upgrade\|第十九章]] | 程序的原子更新与蓝绿部署         | ✅   |
| 21  | [[ch21-debugging-and-verifier\|第二十一章]]       | 调试实战与验证器 (Verifier) 诊断 | ✅   |
| 22  | [[ch22-testing-and-ci-cd\|第二十二章]]            | 测试与持续集成 (CI/CD) 实战      | ✅   |

---

## Part VI：可观测性与 AI (Observability & AI)

全栈可观测性体系与 eBPF 在 AI 基础设施中的前沿应用。

| #    | 章节                                                | 主题                                      | 状态 |
| ---- | --------------------------------------------------- | ----------------------------------------- | ---- |
| 14   | [[ch14-ai-llm-inference-monitoring\|第十四章]]      | AI 推理与大模型监控前沿                   | ✅   |
| 25   | [[ch25-full-stack-observability\|第二十五章]]       | 全栈可观测性与端到端追踪                  | ✅   |
| 25.5 | [[ch25-5-stack-trace-correlation\|第二十五.五章]]   | 调用栈 (Stack Trace) 与业务请求的深度绑定 | ✅   |
| 27   | [[ch27-agent-engineering-architecture\|第二十七章]] | 工业级模块化 Agent 架构演进               | ✅   |

---

## Part VII：安全攻防 (Security & Defense)

从权限模型到 Rootkit 防御，构建完整的 eBPF 安全知识体系。

| #   | 章节                                                  | 主题                     | 状态 |
| --- | ----------------------------------------------------- | ------------------------ | ---- |
| 23  | [[ch23-security-and-permissions\|第二十三章]]         | 权限细分与 BPF 安全沙箱  | ✅   |
| 24  | [[ch24-meta-monitoring-and-self-healing\|第二十四章]] | 内核自愈与 BPF 元监控    | ✅   |
| 26  | [[ch26-network-security-high-level\|第二十六章]]      | 网络安全防御的高阶实战   | ✅   |
| 28  | [[ch28-offensive-and-defensive\|第二十八章]]          | 攻防博弈与 Rootkit 防御  | ✅   |
| 31  | [[ch31-signed-objects-and-security\|第三十一章]]      | 内核原生签名与供应链安全 | ✅   |
| 34  | [[ch34-waf-and-rasp\|第三十四章]]                     | 内核态 WAF 与 RASP       | ✅   |

---

## Part VIII：前沿与跨平台 (Frontier & Cross-Platform)

跨操作系统、硬件卸载、Serverless、绿色计算等 2026 年最前沿话题。

| #    | 章节                                                | 主题                                     | 状态 |
| ---- | --------------------------------------------------- | ---------------------------------------- | ---- |
| 16   | [[ch16-ebpf-and-wasm\|第十六章]]                    | eBPF 与 WebAssembly (WASM) 的共生架构    | ✅   |
| 30   | [[ch30-hardware-offload\|第三十章]]                 | 硬件卸载与 SmartNIC 实战                 | ✅   |
| 32   | [[ch32-ebpf-for-windows\|第三十二章]]               | 跨平台崛起——eBPF for Windows             | ✅   |
| 32.5 | [[ch32-5-macos-status\|第三十二.五章]]              | macOS 的特殊路径——DTrace、ESF 与 bpftime | 🚧   |
| 33   | [[ch33-serverless-optimization\|第三十三章]]        | Serverless 冷启动消除与动态计费          | 🚧   |
| 35   | [[ch35-npu-tpu-ai-hardware\|第三十五章]]            | AI 推理硬件 (NPU/TPU) 与硬件定义内核     | 🚧   |
| 36   | [[ch36-dynamic-language-introspection\|第三十六章]] | 动态语言感知——业务对象的零代码提取       | 🚧   |
| 37   | [[ch37-green-computing\|第三十七章]]                | 绿色计算与能耗精准归因                   | 🚧   |
| 38   | [[ch38-ecosystem-and-career\|第三十八章]]           | 2026 生态全景与工程师职业导航            | 🚧   |

---

## 推荐阅读路径

```
入门基础线:  Ch1 → 1.5 → 1.6 → 2 → 2.5 → 3 → 4
网络性能线:  Ch5 → 6 → 9 → 29 → 29.5
安全攻防线:  Ch7 → 23 → 26 → 28 → 31 → 34
可观测性线:  Ch4 → 13 → 25 → 25.5 → 14 → 27
工程实践线:  Ch8 → 12 → 18 → 19 → 21 → 22
前沿探索线:  Ch16 → 20 → 30 → 32 → 35 → 36
```

---

## 配套资源

- [[2026-04-08-ebpf-comprehensive-learning-roadmap|全栈学习路径总览]] — 学习路线图与优先级建议
- [[2026-04-01-ebpf-call-mechanisms-helpers-vs-kfunc|eBPF 函数调用机制：Helpers vs kfunc]] — 独立专题
- [[2026-04-01-ebpf-kfunc-weak-linking-feature-detection|eBPF kfunc 弱链接与特性检测]] — 独立专题
