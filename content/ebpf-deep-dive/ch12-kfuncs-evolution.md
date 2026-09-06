---
title: "eBPF 深度探索 (十二)：kfuncs 下一代内核交互标准"
date: 2026-04-08
tags:
  - ebpf
  - kfuncs
  - btf
  - kernel-api
  - evolution
---

> [!info] eBPF 2026 深度探索系列 0. [[2026-04-08-ebpf-comprehensive-learning-roadmap|全栈学习路径总览]]
>
> 1. [[ch1-registers-and-instructions|第一章：寄存器与指令集]]
> 2. [[ch1-5-function-calls|第一.五章：四种函数调用与动态内存]]
> 3. [[ch1-6-the-verifier|第一.六章：验证器 (Verifier) 的底层逻辑]]
> 4. [[ch2-maps-and-communication|第二章：Map 机制与跨空间通信]]
> 5. [[ch2-5-kptr-and-ownership|第二.五章：kptr (内核指针) 与内存所有权模型]]
> 6. [[ch3-core-and-btf|第三章：CO-RE 与 BTF 的跨版本魔法]]
> 7. [[ch4-tracing-hooks-and-security|第四章：从 kprobe 到 LSM 的追踪全图景]]
> 8. [[ch7-5-uprobes-dynamic-tracing|第七.五章：uprobe 用户态动态追踪原理]]
> 9. [[ch7-6-bpftime-user-runtime|第七.六章：bpftime 与用户态 eBPF 加速]]
> 10. [[ch18-bpftime-injection-mastery|第七.七章：bpftime 自动化注入与全量监控实战]]
> 11. [[ch7-8-uprobe-selection-guide|第七.八章：uprobe 选型指南：内核态 vs 用户态]]
> 12. [[ch5-xdp-networking-performance|第五章：XDP 极致网络性能与全栈架构]]
> 13. [[ch6-tc-traffic-control|第六章：TC (Traffic Control) 流量调度艺术]]
> 14. [[ch7-security-lsm-enforcement|第七章：LSM BPF 从可观测到安全执法]]
> 15. [[ch8-advanced-tuning-and-profiling|第八章：进阶实战与内核调优]]
> 16. [[ch9-af-xdp-zero-copy|第九章：AF_XDP 零拷贝与用户态协议栈]]
> 17. [[ch10-sched-ext-custom-scheduler|第十章：sched_ext 自定义 CPU 调度器]]
> 18. [[ch11-bpf-iterators|第十一章：BPF Iterators 内核对象迭代器]]
> 19. **第十二章：kfuncs 下一代内核交互标准**
> 20. [[ch13-usdt-tracing|第十三章：USDT 用户态静态定义追踪]]
> 21. [[ch14-ai-llm-inference-monitoring|第十四章：AI 推理与大模型监控前沿]]
> 22. [[ch15-container-isolation|第十五章：无感增强容器隔离性]]
> 23. [[ch16-ebpf-and-wasm|第十六章：eBPF 与 WebAssembly (WASM) 的共生架构]]
> 24. [[ch17-storage-and-filesystem|第十七章：存储与文件系统加速]]
> 25. [[ch18-lifecycle-and-links|第十八章：生命周期管理与 BPF Links]]
> 26. [[ch19-atomic-updates-and-hot-upgrade|第十九章：程序的原子更新与蓝绿部署]]
> 27. [[ch25-5-stack-trace-correlation|第二五.五章：调用栈与业务请求的深度绑定]]
> 28. [[ch20-edge-iot-acceleration|第二十章：边缘计算与工业协议加速]]
> 29. [[ch21-debugging-and-verifier|第二十一章：调试实战与验证器 (Verifier) 诊断]]
> 30. [[ch22-testing-and-ci-cd|第二十二章：测试与持续集成 (CI/CD) 实战]]
> 31. [[ch23-security-and-permissions|第二十三章：权限细分与 BPF 安全沙箱]]
> 32. [[ch24-meta-monitoring-and-self-healing|第二十四章：eBPF 程序的内核自愈与监控]]
> 33. [[ch25-full-stack-observability|第二十五章：全栈可观测性与端到端追踪]]
> 34. [[ch26-network-security-high-level|第二十六章：网络安全防御的高阶实战]]
> 35. [[ch27-agent-engineering-architecture|第二十七章：工业级模块化 Agent 架构演进]]
> 36. [[ch28-offensive-and-defensive|第二十八章：攻防博弈与 Rootkit 防御]]
> 37. [[ch29-networking-deep-dive|第二十九章：网络应用深水区——负载均衡、Sockmap 与拥塞控制]]
> 38. [[ch30-hardware-offload|第三十章：硬件卸载与 SmartNIC 实战]]
> 39. [[ch31-signed-objects-and-security|第三十一章：内核原生签名与供应链安全]]
> 40. [[ch32-ebpf-for-windows|第三十二章：跨平台崛起——eBPF for Windows]]
> 41. [[ch32-5-macos-status|第三十二.五章：macOS 的特殊路径]]
> 42. [[ch33-serverless-optimization|第三十三章：Serverless 冷启动消除与动态计费]]
> 43. [[ch34-waf-and-rasp|第三十四章：Web 安全革命——内核态 WAF 与 RASP]]
> 44. [[ch35-npu-tpu-ai-hardware|第三十五章：AI 推理硬件 (NPU/TPU) 与硬件定义内核]]
> 45. [[ch36-dynamic-language-introspection|第三十六章：动态语言感知——业务对象的零代码提取]]
> 46. [[ch37-green-computing|第三十七章：绿色计算与能耗精准归因]]
> 47. [[ch38-ecosystem-and-career|第三十八章：2026 生态全景与工程师职业导航]]
> 48. [[ch39-rust-aya-framework|第三十九章：Rust eBPF 开发实战——Aya 框架与安全编程]]
> 49. [[ch40-network-protocols-deep-dive|第四十章：网络协议深度解析——TCP/UDP/QUIC 的 eBPF 视角]]
> 50. [[ch41-memory-safety-and-vulnerabilities|第四十一章：eBPF 内存安全与漏洞分析]]
> 51. [[ch42-service-mesh-integration|第四十二章：eBPF 与 Service Mesh 深度集成]]

---

## 1. 概述：从"封闭"向"开放"的转变

在 eBPF 的演进史上，**kfuncs (Kernel Functions)** 的出现标志着内核可编程性进入了爆发期。

长期以来，eBPF 程序只能调用数量有限且固定的 **BPF Helpers**。如果开发者需要一个新的内核接口，必须向主线内核提交补丁，等待漫长的发布周期。**kfuncs** 彻底打破了这一僵局：它允许内核及其模块动态地将现有的 C 函数暴露给 eBPF，实现了接口的高速迭代。

### 1.1 什么是 kfuncs？

kfuncs 是内核函数 (Kernel Functions) 的缩写，是一套允许 eBPF 程序直接调用内核 C 函数的机制。与 BPF Helpers 不同，kfuncs 不是通过预定义的整数 ID 来引用，而是通过 **BTF (BPF Type Format)** 进行类型安全的符号级调用。

从本质上讲，kfuncs 就是普通的内核函数，只不过它们通过特定的宏注册到了 BPF 子系统中，并附带了一组语义标记，让 eBPF 验证器 (Verifier) 能够理解函数的行为特性——比如是否返回空指针、是否获取了引用计数、是否需要在 RCU 保护下调用等。

### 1.2 历史演进

| 阶段         | 时间             | 关键事件                                                 |
| ------------ | ---------------- | -------------------------------------------------------- |
| Helper 时代  | 2014-2020        | 所有 eBPF 程序只能通过 `call helper_id` 调用预注册函数   |
| kfuncs 引入  | 5.11 (2021)      | 首次支持通过 BTF 调用内核函数，最初仅限 tracing 类程序   |
| 引用计数支持 | 5.12-5.14        | 引入 `KF_ACQUIRE`/`KF_RELEASE` 标志，支持引用计数安全    |
| 模块级 kfunc | 5.17 (2022)      | 允许内核模块注册 kfunc，彻底打破核心内核限制             |
| 完善与普及   | 5.19-6.x         | 支持更多程序类型、弱链接 (Weak Linking)、sleepable kfunc |
| 成熟期       | 6.8+ (2024-2026) | kfuncs 成为新内核功能的默认暴露方式，数量超过 300 个     |

---

## 2. kfuncs vs BPF Helpers：全面对比

在深入技术细节之前，我们首先需要清晰地理解 kfuncs 与传统 BPF Helpers 之间的区别。这两者并非简单的替代关系，而是在不同场景下各有优势。

### 2.1 核心差异总览

| 维度             | BPF Helpers                                  | kfuncs                                           |
| ---------------- | -------------------------------------------- | ------------------------------------------------ |
| **标识方式**     | 整数 ID（如 `BPF_FUNC_map_lookup_elem = 1`） | BTF 符号名（如 `bpf_get_file_by_fd`）            |
| **注册位置**     | 硬编码在 `kernel/bpf/helpers.c` 等核心文件中 | 可注册在任意内核源文件或内核模块中               |
| **类型安全**     | 仅在运行时检查参数类型                       | 通过 BTF 在加载时进行完整的类型校验              |
| **扩展方式**     | 修改内核源码，提交上游补丁                   | 编写独立模块，使用 `register_btf_kfunc_id_set()` |
| **跨版本兼容**   | 依赖 Helper ID 稳定性，通常向后兼容          | 依赖 BTF 类型定义，通过弱链接实现版本适配        |
| **调用开销**     | 通过 Helper 调用表间接跳转                   | JIT 直接生成原生 `call` 指令                     |
| **语义标注**     | 无（Helper 行为由 ID 隐式决定）              | 通过 `KF_*` 标志显式声明行为语义                 |
| **适用程序类型** | 大多数程序类型                               | 逐步扩展，tracing/LSM 已全面支持                 |

### 2.2 调用路径对比

**Helper 调用路径：**

```
eBPF 指令: call <helper_id>
  -> 解释器/JIT 查找 helper 调用表
  -> 间接跳转到 handler 函数
  -> handler 内部参数解包与安全检查
  -> 执行实际逻辑
```

**kfunc 调用路径：**

```
eBPF 指令: call <kfunc_address>
  -> 直接跳转到内核函数
  -> 执行实际逻辑（函数本身已包含安全检查）
```

可以看到，kfunc 的调用路径短得多。JIT 编译器可以直接将 kfunc 调用编译为一条原生 `call` 指令，消除了 Helper 调用中的间接跳转开销。在性能敏感的场景（如 XDP 报文处理路径），这种差异至关重要。

### 2.3 何时选择 kfuncs，何时选择 Helpers？

- **选择 Helpers**：当你需要最大兼容性（旧内核支持）、或使用已有成熟 Helper 接口时
- **选择 kfuncs**：当你需要访问内核数据结构、操作引用计数、使用模块级功能、或追求极致性能时

---

## 3. kfuncs 的底层支柱：BTF

不同于 Helpers 使用整数 ID 进行调用，kfuncs 的调用完全基于 **BTF (BPF Type Format)** 元数据。

### 3.1 BTF 的角色

BTF 是 kfuncs 机制的核心基础。它不仅仅是一个类型描述格式，更是连接 eBPF 程序与内核函数的桥梁：

- **类型安全**：编译器和验证器在加载前就能确切知道 kfunc 期望的结构体类型。如果 BPF 程序声明的参数类型与内核 BTF 中定义的类型不匹配，验证器将直接拒绝加载。
- **符号发现**：libbpf 通过遍历 `/sys/kernel/btf/vmlinux` 来发现可用的 kfunc，无需维护硬编码的 ID 表。
- **版本兼容**：BTF 类型信息随内核一起发布，CO-RE 机制可以在编译时和加载时进行类型匹配和重定位。

### 3.2 BTF 注解与语义标记

内核通过在 kfunc 的 BTF 信息中附加特定的注解来告知验证器该函数的行为特性。这些注解直接影响验证器如何分析和约束 eBPF 程序：

- **`__acquire` / `__release`**：标注函数是否涉及引用计数或锁的操作。当 kfunc 标记为 `__acquire` 时，验证器会追踪返回指针的生命周期，确保在程序退出前调用对应的 `__release` kfunc 进行释放。
- **`__nullable`**：标注指针参数或返回值是否可以为空，强制 eBPF 程序进行 NULL 检查。
- **`__sz`**：标注大小参数，与特定指针参数关联，帮助验证器进行数组越界检查。
- **`__kptr`**：标注参数是指向已获取引用计数的内核指针，验证器会验证其有效性。

### 3.3 BTF 类型信息示例

在内核编译时，`pahole` 工具会从 DWARF 调试信息中提取类型信息并生成 BTF。对于 kfunc，BTF 中不仅包含函数签名，还包含附加的 `btf_decl_tag` 记录来存储语义标记：

```c
// 内核源码中的 kfunc 定义
__bpf_kfunc struct task_struct *bpf_task_acquire(struct task_struct *p);

// 对应的 BTF 信息（简化表示）
// FUNC_PROTO (struct task_struct *) bpf_task_acquire
//   PARAM (struct task_struct *) p
// DECL_TAG "btf_decl_tag" -> __acquire (关联到返回值)
// DECL_TAG "btf_decl_tag" -> __nullable (关联到参数 p)
```

---

## 4. kfunc 注册机制：KF\_\* 标志详解

一个普通的内核函数并不会自动成为 kfunc。其注册过程涉及内核侧的显式导出与加载侧的动态绑定。理解 `KF_*` 标志是掌握 kfuncs 的关键。

### 4.1 KF_ACQUIRE：获取资源

`KF_ACQUIRE` 标记表示该 kfunc 会获取一个内核对象的引用计数，或分配新资源。验证器会将返回值标记为"已获取引用"，并要求程序在退出前释放该引用。

```c
// 获取 task_struct 的引用，增加引用计数
__bpf_kfunc struct task_struct *bpf_task_acquire(struct task_struct *p);

// 注册时标记 KF_ACQUIRE
BTF_ID_FLAGS(func, bpf_task_acquire, KF_ACQUIRE | KF_RET_NULL | KF_TRUSTED_ARGS)
```

关键语义：

- 返回的指针拥有一个引用计数
- 如果 kfunc 同时标记了 `KF_RET_NULL`，验证器要求调用者检查返回值是否为 NULL
- 该指针可以被存储到 Map 中（通过 kptr）或传递给其他 kfunc

### 4.2 KF_RELEASE：释放资源

`KF_RELEASE` 是 `KF_ACQUIRE` 的配对操作，表示该 kfunc 会释放一个之前通过 `KF_ACQUIRE` 获取的内核对象的引用计数。

```c
// 释放 task_struct 的引用，减少引用计数
__bpf_kfunc void bpf_task_release(struct task_struct *p);

// 注册时标记 KF_RELEASE
BTF_ID_FLAGS(func, bpf_task_release, KF_RELEASE)
```

关键语义：

- 验证器会追踪所有通过 `KF_ACQUIRE` 获取的指针
- 如果程序退出时仍有未释放的引用，验证器将拒绝加载
- 防止引用计数泄漏，这是内核中最常见的 bug 类型之一

### 4.3 KF_RET_NULL：可能返回空指针

`KF_RET_NULL` 告知验证器该 kfunc 可能返回 NULL 指针。验证器会强制调用者在使用返回值前进行 NULL 检查。

```c
// 通过 PID 查找 task，可能不存在
__bpf_kfunc struct task_struct *bpf_task_from_pid(s32 pid);

// 注册
BTF_ID_FLAGS(func, bpf_task_from_pid, KF_ACQUIRE | KF_RET_NULL | KF_TRUSTED_ARGS)
```

验证器行为：

```c
struct task_struct *task = bpf_task_from_pid(target_pid);
// 验证器在此插入分支约束：task 必须经过 NULL 检查
if (!task)
    return 0;  // 安全退出

// 此处验证器知道 task != NULL
bpf_printk("Found task: %d", task->pid);
bpf_task_release(task);  // 必须释放
```

### 4.4 KF_TRUSTED_ARGS：信任参数来源

`KF_TRUSTED_ARGS` 表示 kfunc 期望其参数来自受信任的来源。这通常意味着参数必须是：

- 来自另一个 kfunc 的返回值（如 `KF_ACQUIRE` 返回的指针）
- 来自 Map 中的 kptr
- 来自程序上下文（如 tracepoint 参数）

这防止了 eBPF 程序传入伪造的指针地址给内核函数。

### 4.5 其他重要标志

| 标志                                               | 含义                                        | 使用场景                       |
| -------------------------------------------------- | ------------------------------------------- | ------------------------------ |
| `KF_RCU`                                           | 函数必须在 RCU 读锁定保护下调用             | 访问 RCU 保护的数据结构        |
| `KF_SLEEPABLE`                                     | 函数可能睡眠，仅在 sleepable BPF 程序中可用 | 需要获取互斥锁、分配内存等     |
| `KF_DESTRUCTIVE`                                   | 函数可能修改系统状态（如关闭文件）          | LSM 钩子中的安全决策函数       |
| `KF_ITER_NEW` / `KF_ITER_NEXT` / `KF_ITER_DESTROY` | 标记迭代器 kfunc 的三阶段                   | BPF Iterator 的 begin/next/end |

### 4.6 标志组合示例

一个 kfunc 可以同时携带多个标志。以下是一些真实的内核 kfunc 及其标志组合：

```c
// 获取当前任务的 cgroup 引用
BTF_ID_FLAGS(func, bpf_cgroup_acquire, KF_ACQUIRE | KF_TRUSTED_ARGS)

// 通过 fd 获取文件对象
BTF_ID_FLAGS(func, bpf_get_file_by_fd, KF_ACQUIRE | KF_RET_NULL)

// 释放文件对象引用
BTF_ID_FLAGS(func, bpf_put_file, KF_RELEASE)

// 查找任务（可能返回 NULL，需要 RCU 保护）
BTF_ID_FLAGS(func, bpf_task_from_pid, KF_ACQUIRE | KF_RET_NULL | KF_TRUSTED_ARGS)

// 可睡眠的分配函数
BTF_ID_FLAGS(func, bpf_obj_new_impl, KF_ACQUIRE | KF_RET_NULL | KF_SLEEPABLE)
```

---

## 5. 完整调用链：从声明到执行

理解 kfunc 的完整调用链路是掌握其工作原理的关键。我们分阶段来看整个过程。

### 5.1 编译时：\_\_ksym 声明

在 BPF 程序中，开发者使用 `extern` 关键字配合 `__ksym` 属性声明目标函数：

```c
// 声明 ksym —— 编译器不会生成跳转代码，而是保留符号占位符
extern struct file *bpf_get_file_by_fd(u32 fd) __ksym;
extern void bpf_put_file(struct file *file) __ksym;
extern struct task_struct *bpf_task_acquire(struct task_struct *p) __ksym;
extern void bpf_task_release(struct task_struct *p) __ksym;
```

编译器在看到 `__ksym` 属性时，会：

1. 在 `.ksyms` 段中创建一个符号引用条目
2. 在目标 BPF 指令中生成一个 `call` 指令，目标地址暂填 0
3. 将类型信息记录到 BTF 中，供后续重定位使用

### 5.2 加载时：libbpf 动态绑定

当程序通过 `bpf_object__load()` 加载时，`libbpf` 执行以下"重定位"动作：

1. **符号匹配**：在 `/sys/kernel/btf/vmlinux` 中检索该函数的 BTF ID
2. **类型强校验**：对比 BPF 程序中的声明与内核真实的 BTF 定义。如果参数数量或类型不匹配，拒绝加载并给出详细错误信息
3. **指令修补**：将 BPF 指令中的占位地址替换为内核函数的**真实内存地址**
4. **验证器介入**：BPF 验证器根据 kfunc 的 `KF_*` 标志，对程序进行额外的约束检查

### 5.3 运行时：JIT 原生调用

最终，JIT 编译器将 kfunc 调用编译为机器码级别的原生 `call` 指令。对于 x86_64 架构，这意味着：

```asm
// JIT 编译后的 kfunc 调用（简化）
mov rdi, [rsi + offset_fd]    ; 加载参数
call 0xffffffff81234567        ; 直接调用内核函数地址
test rax, rax                  ; 检查返回值（KF_RET_NULL）
jz   error_handler
```

这种直接调用方式消除了 Helper 调用中的间接跳转，在热路径（如 XDP）上可以节省数个时钟周期。

---

## 6. 实战演示：获取并释放内核资源

下面的代码展示了如何使用 kfuncs 获取一个内核文件的引用计数，并安全地进行释放。

```c
// 声明 ksym
extern struct file *bpf_get_file_by_fd(u32 fd) __ksym;
extern void bpf_put_file(struct file *file) __ksym;

SEC("lsm/file_open")
int BPF_PROG(test_kfunc, struct file *file) {
    struct file *f;

    // 1. 调用 kfunc 获取文件对象
    // bpf_get_file_by_fd 标记了 KF_ACQUIRE | KF_RET_NULL
    // 验证器要求我们检查 NULL
    f = bpf_get_file_by_fd(3);

    if (f) {
        // 2. 安全使用文件对象
        bpf_printk("File flags: %x", f->f_flags);

        // 3. 验证器会确保你最终释放了引用计数
        // bpf_put_file 标记了 KF_RELEASE
        bpf_put_file(f);
    }

    return 0;
}
```

### 6.1 验证器的引用追踪

上面的代码中，验证器会执行以下分析：

1. `bpf_get_file_by_fd` 返回 `struct file *`，标记为 `KF_ACQUIRE | KF_RET_NULL`
2. 验证器在 `if (f)` 之后创建两个分支：
   - **true 分支**：`f` 为非 NULL，拥有一个引用计数
   - **false 分支**：`f` 为 NULL，无需处理
3. 在 true 分支中，`bpf_put_file(f)` 释放引用（`KF_RELEASE`）
4. 验证器确认所有路径上引用都被正确释放，允许加载

如果开发者忘记调用 `bpf_put_file`，验证器将报错：

```
ERROR: uninitialized_ptr_subprog
  program references a resource that was not released
```

---

## 7. 实战演示：任务结构体操作

以下示例展示更复杂的 kfunc 使用模式，包括任务查找、cgroup 操作和引用计数传递。

```c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

// 声明所需的 kfuncs
extern struct task_struct *bpf_task_from_pid(s32 pid) __ksym;
extern struct task_struct *bpf_task_acquire(struct task_struct *p) __ksym;
extern void bpf_task_release(struct task_struct *p) __ksym;
extern struct cgroup *bpf_task_cgroup(struct task_struct *task) __ksym;
extern struct cgroup *bpf_cgroup_acquire(struct cgroup *cgrp) __ksym;
extern void bpf_cgroup_release(struct cgroup *cgrp) __ksym;

// 定义存储任务指针的 Map
struct {
    __uint(type, BPF_MAP_TYPE_TASK_STORAGE);
    __uint(map_flags, BPF_F_NO_PREALLOC);
    __type(key, int);
    __type(value, u64);
} task_storage SEC(".maps");

SEC("tp_btf/sched_process_exec")
int BPF_PROG(trace_exec, struct task_struct *p, pid_t old_pid,
             struct linux_binprm *bprm)
{
    struct task_struct *target;
    struct cgroup *cgrp;
    s32 pid = (s32)(bpf_get_current_pid_tgid() >> 32);

    // 1. 通过 PID 查找任务（KF_ACQUIRE | KF_RET_NULL）
    target = bpf_task_from_pid(pid);
    if (!target)
        return 0;

    // 2. 获取任务的 cgroup（返回的是无引用的指针，需要 acquire）
    cgrp = bpf_task_cgroup(target);
    if (cgrp) {
        struct cgroup *acquired_cgrp = bpf_cgroup_acquire(cgrp);
        if (acquired_cgrp) {
            bpf_printk("Task %d in cgroup id %llu",
                       pid, acquired_cgrp->kn->id);
            bpf_cgroup_release(acquired_cgrp);
        }
    }

    // 3. 释放任务引用
    bpf_task_release(target);
    return 0;
}
```

### 7.1 关键设计模式

这个示例展示了三个重要的 kfunc 使用模式：

1. **Acquire-Release 配对**：每个 `KF_ACQUIRE` 必须有对应的 `KF_RELEASE`
2. **引用计数传递**：`bpf_task_cgroup` 返回一个无引用的指针，必须通过 `bpf_cgroup_acquire` 获取引用后才能安全使用
3. **多层 NULL 检查**：由于多个 kfunc 都可能返回 NULL（`KF_RET_NULL`），每一层都需要进行 NULL 检查

---

## 8. Weak Linking：跨版本兼容的艺术

在 2026 年，内核版本碎片化是 eBPF 程序面临的最大挑战之一。一个在 6.8 内核上运行良好的程序，可能在 5.15 内核上完全无法加载，因为某些 kfunc 在旧版本中不存在。

### 8.1 传统方案的困境

```c
// 这个 kfunc 在 6.1 内核中才引入
extern struct cgroup *bpf_cgroup_ancestor(struct cgroup *cgrp, int level) __ksym;

// 在 5.19 内核上加载时，libbpf 会直接报错并拒绝加载
```

### 8.2 弱链接解决方案

通过 `__weak` 标记，可以声明一个"可选"的 kfunc 引用。如果运行时内核没有该符号，libbpf 会自动将调用替换为 `bpf_kfunc_call_test_replace`（返回 0 的占位函数），而不是拒绝加载。

```c
// 弱链接声明 —— 即使内核不支持也不会导致加载失败
extern struct cgroup *bpf_cgroup_ancestor(struct cgroup *cgrp,
                                          int level) __ksym __weak;

SEC("tp_btf/sched_switch")
int BPF_PROG(trace_switch, bool preempt, struct task_struct *prev,
             struct task_struct *next)
{
    struct cgroup *root = bpf_cgroup_ancestor(next->cgroups->dfl_cgrp, 0);

    // 弱链接下，如果 kfunc 不存在，root 将为 NULL
    if (root) {
        bpf_printk("Root cgroup id: %llu", root->kn->id);
    } else {
        bpf_printk("bpf_cgroup_ancestor not available on this kernel");
    }

    return 0;
}
```

### 8.3 弱链接的实现原理

1. **编译时**：`__weak` 标记使得 `libbpf` 在重定位阶段将该符号标记为"可选"
2. **加载时**：如果 `/sys/kernel/btf/vmlinux` 中找不到该符号，`libbpf` 不会报错，而是将调用目标替换为一个返回 0 的占位函数
3. **验证器处理**：对于弱链接的 kfunc，验证器不会强制执行 `KF_*` 标志相关检查（因为占位函数没有这些标志）
4. **运行时**：BPF 程序可以通过检查返回值是否为 NULL/0 来判断该 kfunc 是否真正可用

### 8.4 版本检测模式

结合弱链接和特征检测，可以编写自适应的 eBPF 程序：

```c
extern u64 bpf_get_current_task_btf __ksym __weak;
extern u64 bpf_task_vma_nr_pages __ksym __weak;

SEC("tp_btf/sys_enter")
int BPF_PROG(detect_features) {
    // 检测哪些 kfunc 可用
    bool has_task_btf = !!(&bpf_get_current_task_btf != NULL);
    bool has_vma_pages = !!(&bpf_task_vma_nr_pages != NULL);

    bpf_printk("Features: task_btf=%d, vma_pages=%d",
               has_task_btf, has_vma_pages);
    return 0;
}
```

---

## 9. 内核模块 kfuncs：插件化扩展

kfunc 与 Helper 函数在工程上最大的区别在于：**Helper 必须静态编译进内核，而 kfunc 可以通过内核模块（LKM）动态注入。**

### 9.1 模块化开发的优势

在 2026 年，如果你需要一个内核尚未提供的特殊功能（如自定义协议解析、硬件加速接口）：

1. **无需修改内核主线**：你可以编写一个独立的驱动模块，利用 `register_btf_kfunc_id_set()` 在初始化时注册自定义函数。
2. **热插拔支持**：加载模块，eBPF 程序即可调用新函数；卸载 BPF 程序后，模块亦可安全卸载。内核会自动管理两者之间的引用计数，防止 Use-After-Free。

### 9.2 完整的内核模块示例

以下是一个完整的内核模块，展示了如何注册自定义 kfunc 并处理多程序类型：

```c
// my_kfunc_mod.c —— 自定义 kfunc 内核模块
#include <linux/module.h>
#include <linux/btf.h>
#include <linux/btf_ids.h>
#include <linux/skbuff.h>

// 1. 实现自定义逻辑：计算网络流量的魔数哈希
__bpf_kfunc u64 bpf_calc_magic_number(u32 input)
{
    return (u64)input * 0xDEADC0DE;
}

// 2. 实现更复杂的 kfunc：解析 skb 并提取自定义元数据
__bpf_kfunc int bpf_skb_extract_metadata(struct __sk_buff *skb_ctx,
                                         u64 *out_hash, u32 *out_len)
{
    struct sk_buff *skb = (struct sk_buff *)skb_ctx;
    if (!skb || !out_hash || !out_len)
        return -EINVAL;

    *out_hash = skb_get_hash(skb) ^ 0xCAFEBABE;
    *out_len = skb->len;
    return 0;
}

// 3. 支持引用计数的 kfunc
struct my_resource {
    u64 id;
    refcount_t refcnt;
};

__bpf_kfunc struct my_resource *bpf_my_resource_alloc(u64 id)
{
    struct my_resource *res;

    res = kmalloc(sizeof(*res), GFP_KERNEL);
    if (!res)
        return NULL;

    res->id = id;
    refcount_set(&res->refcnt, 1);
    return res;
}

__bpf_kfunc void bpf_my_resource_release(struct my_resource *res)
{
    if (res && refcount_dec_and_test(&res->refcnt))
        kfree(res);
}

__bpf_kfunc u64 bpf_my_resource_get_id(struct my_resource *res)
{
    return res ? res->id : 0;
}

// 4. 将所有函数注册到 BTF ID 集合
BTF_SET8_START(my_custom_kfunc_set)
BTF_ID_FLAGS(func, bpf_calc_magic_number)
BTF_ID_FLAGS(func, bpf_skb_extract_metadata, KF_TRUSTED_ARGS)
BTF_ID_FLAGS(func, bpf_my_resource_alloc, KF_ACQUIRE | KF_RET_NULL | KF_SLEEPABLE)
BTF_ID_FLAGS(func, bpf_my_resource_release, KF_RELEASE)
BTF_ID_FLAGS(func, bpf_my_resource_get_id, KF_TRUSTED_ARGS)
BTF_SET8_END(my_custom_kfunc_set)

// 5. 定义 kfunc 注册信息，支持多个程序类型
static const struct btf_kfunc_id_set my_kfunc_ids = {
    .owner = THIS_MODULE,
    .set   = &my_custom_kfunc_set,
};

// 6. 模块初始化：注册到多个 BPF 程序类型
static int __init my_mod_init(void)
{
    int ret;
    const enum bpf_prog_type prog_types[] = {
        BPF_PROG_TYPE_TRACING,
        BPF_PROG_TYPE_XDP,
        BPF_PROG_TYPE_LSM,
    };

    for (int i = 0; i < ARRAY_SIZE(prog_types); i++) {
        ret = register_btf_kfunc_id_set(prog_types[i], &my_kfunc_ids);
        if (ret) {
            pr_err("Failed to register kfuncs for prog type %d: %d\n",
                   prog_types[i], ret);
            return ret;
        }
    }

    pr_info("Custom kfunc module loaded successfully\n");
    return 0;
}

static void __exit my_mod_exit(void)
{
    pr_info("Custom kfunc module unloaded\n");
}

module_init(my_mod_init);
module_exit(my_mod_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Custom BPF kfunc module");
MODULE_AUTHOR("eBPF Developer");
```

### 9.3 BPF 程序侧：调用模块 kfunc

```c
// my_kfunc_user.c —— 使用模块 kfunc 的 BPF 程序
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

// 声明模块提供的 kfuncs
extern u64 bpf_calc_magic_number(u32 input) __ksym;
extern int bpf_skb_extract_metadata(struct __sk_buff *skb_ctx,
                                    u64 *out_hash, u32 *out_len) __ksym;
extern struct my_resource *bpf_my_resource_alloc(u64 id) __ksym;
extern void bpf_my_resource_release(struct my_resource *res) __ksym;
extern u64 bpf_my_resource_get_id(struct my_resource *res) __ksym;

SEC("fentry/vfs_open")
int BPF_PROG(trace_open, struct inode *inode, struct file *file)
{
    u32 pid = bpf_get_current_pid_tgid() >> 32;

    // 调用自定义的 kfunc
    u64 magic = bpf_calc_magic_number(pid);
    bpf_printk("Custom kfunc result: %llu", magic);

    // 使用带引用计数的 kfunc
    struct my_resource *res = bpf_my_resource_alloc(pid);
    if (res) {
        u64 res_id = bpf_my_resource_get_id(res);
        bpf_printk("Allocated resource id: %llu", res_id);
        bpf_my_resource_release(res);
    }

    return 0;
}
```

### 9.4 模块生命周期管理

内核提供了完善的模块引用计数管理机制：

- **加载 BPF 程序时**：如果程序引用了某个模块的 kfunc，内核自动增加该模块的引用计数
- **卸载 BPF 程序时**：内核自动减少模块的引用计数
- **尝试卸载模块时**：如果有 BPF 程序仍在使用该模块的 kfunc，`rmmod` 将失败并提示 `Module is in use`
- **这完全自动化**，开发者无需手动管理引用计数

### 9.5 构建与部署

```bash
# 构建 Makefile
# Makefile
obj-m := my_kfunc_mod.o
KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

# 加载模块
sudo insmod my_kfunc_mod.ko

# 验证 kfunc 已注册
bpftool btf dump file /sys/kernel/btf/vmlinux format c | grep bpf_calc_magic_number

# 加载 BPF 程序
sudo bpftool prog load my_kfunc_user.bpf.o /sys/fs/bpf/my_prog

# 卸载
sudo bpftool prog unload /sys/fs/bpf/my_prog
sudo rmmod my_kfunc_mod
```

---

## 10. kfunc 与 Map kptr：内存所有权模型

kfuncs 的 `KF_ACQUIRE`/`KF_RELEASE` 机制与 Map 中的 kptr 功能紧密结合，构成了 eBPF 的内存所有权模型。这部分内容在 [[ch2-5-kptr-and-ownership|第二.五章：kptr 与内存所有权模型]] 中有更详细的讨论，这里我们聚焦于 kfunc 在其中的角色。

### 10.1 将 kfunc 获取的指针存入 Map

```c
// 定义支持 kptr 的 Map
struct my_obj {
    int refcount;
    int data;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, u32);
    __type(value, struct my_obj *);
    __type(map_value_type, struct my_obj);  // 启用 kptr 支持
} obj_map SEC(".maps");

extern struct my_obj *bpf_my_obj_alloc(int data) __ksym;
extern void bpf_my_obj_release(struct my_obj *obj) __ksym;

SEC("tp_btf/sys_enter")
int BPF_PROG(store_obj)
{
    u32 key = 1;
    struct my_obj *obj = bpf_my_obj_alloc(42);

    if (!obj)
        return 0;

    // 将引用转移给 Map（引用计数从 BPF 程序转移到 Map）
    long err = bpf_map_update_elem(&obj_map, &key, &obj, BPF_ANY);
    if (err) {
        // 更新失败，需要手动释放
        bpf_my_obj_release(obj);
    }
    // 成功后 obj 的引用归 Map 所有，程序不再持有

    return 0;
}

SEC("tp_btf/sys_exit")
int BPF_PROG(read_obj)
{
    u32 key = 1;
    struct my_obj **ptr;

    // 从 Map 中读取 kptr
    ptr = bpf_map_lookup_elem(&obj_map, &key);
    if (!ptr || !*ptr)
        return 0;

    // *ptr 是一个受信任的指针，可以直接使用
    bpf_printk("Object data: %d", (*ptr)->data);

    return 0;
}
```

---

## 11. 调试与故障排除

### 11.1 常见错误及解决方案

**错误 1：kfunc 未找到**

```
libbpf: failed to find BTF for extern kfunc 'bpf_calc_magic_number' [#0]
```

原因：内核或模块未加载，或 kfunc 未注册到当前程序类型。检查模块是否已 `insmod`，以及注册的程序类型是否匹配。

**错误 2：类型不匹配**

```
verifier error: kfunc '#0' (bpf_calc_magic_number) arg#0 expected
  'PTR_TO_CTX' but got 'SCALAR_VALUE'
```

原因：传递给 kfunc 的参数类型与 BTF 定义不一致。检查函数声明是否与内核源码完全匹配。

**错误 3：引用泄漏**

```
verifier error: Unreleased reference id=4
```

原因：通过 `KF_ACQUIRE` 获取的资源未在所有路径上通过 `KF_RELEASE` 释放。检查所有分支是否都正确释放了资源。

**错误 4：不受信任的参数**

```
verifier error: kfunc '#0' (bpf_task_release) requires trusted_args but arg#0
  is not a trusted pointer
```

原因：传递给标记了 `KF_TRUSTED_ARGS` 的 kfunc 的参数来源不受信任。确保参数来自另一个 kfunc 的返回值、Map kptr 或程序上下文。

### 11.2 调试工具

```bash
# 查看当前内核可用的所有 kfunc
bpftool btf dump file /sys/kernel/btf/vmlinux format c | \
  grep '__bpf_kfunc' | head -50

# 查看模块提供的 kfunc
bpftool btf dump file /sys/kernel/btf/<module> format c | \
  grep '__bpf_kfunc'

# 查看已加载 BPF 程序的 kfunc 调用
bpftool prog dump xlated id <prog_id>

# 使用 drgn 直接检查 kfunc 注册状态
# (需要 drgn 工具)
```

---

## 12. 从"全家桶"到"插件化"：设计哲学的演进

- **Helpers**：如同出厂自带、无法更改的固定配置。每次新增 Helper 都需要修改内核核心代码，经过漫长的补丁审核流程。
- **kfuncs**：如同 USB 外设，赋予了 Linux 内核"插件化"扩展的能力。驱动开发者可以独立开发、测试、发布新功能，eBPF 程序可以按需使用。

这一设计哲学的转变反映了 Linux 内核社区对 eBPF 定位的重新认识：eBPF 不再仅仅是网络包处理的加速器，而是操作系统的**可编程扩展层**。kfuncs 正是这一扩展层的标准接口协议。

---

## 13. FAQ

### Q1: kfunc 和 Helper 在性能上有多少差异？

对于简单的函数调用，差异通常在 **5-15 个时钟周期**之间。Helper 调用需要通过函数指针表进行间接跳转，而 kfunc 由 JIT 直接编译为原生 `call` 指令。在 XDP 等每秒处理数百万报文的场景中，这个差异可能累计为可观的 CPU 时间节省。但对于大多数追踪和监控场景，这个差异可以忽略不计。

### Q2: 我能否在非 GPL 模块中注册 kfunc？

不能。kfunc 注册 API（`register_btf_kfunc_id_set()`）要求模块使用 `MODULE_LICENSE("GPL")` 或兼容的许可证。这是因为 kfunc 允许 eBPF 程序直接调用模块中的函数，等同于将模块代码暴露给内核，必须遵循 GPL 的 copyleft 要求。

### Q3: 弱链接的 kfunc 如何处理 KF_ACQUIRE/KF_RELEASE 语义？

当弱链接的 kfunc 在运行时不可用时，`libbpf` 会将其替换为返回 0/NULL 的占位函数。验证器在处理弱链接 kfunc 时会**跳过** `KF_*` 相关的语义检查，因为占位函数不执行任何实际操作。这意味着如果程序逻辑依赖 `KF_ACQUIRE` 返回的有效指针，你需要自行添加 NULL 检查来处理 kfunc 不可用的情况。

### Q4: kfunc 可以传递复杂结构体（如嵌套指针）吗？

技术上可以，但验证器会进行严格的类型检查。如果结构体中包含指针字段，验证器需要能够追踪该指针的生命周期和来源。在实践中，推荐传递**简单的 POD (Plain Old Data) 结构体**或**通过 kfunc 获取的受信任指针**。对于复杂的数据交换，使用 BPF Map（如 `BPF_MAP_TYPE_ARRAY` 或 `BPF_MAP_TYPE_HASH`）作为中间媒介通常是更安全的选择。

### Q5: 如何判断我的内核是否支持某个特定的 kfunc？

有三种方法：

1. **检查内核源码**：在内核源码中搜索 `BTF_ID_FLAGS(func, <kfunc_name>` 或使用 `grep -r "__bpf_kfunc" kernel/`
2. **使用 bpftool**：`bpftool btf dump file /sys/kernel/btf/vmlinux format c | grep <kfunc_name>`
3. **编程检测**：在 BPF 程序中使用 `__weak` 声明 kfunc，通过检查返回值是否为 NULL 来判断是否可用（推荐，可实现运行时自适应）
