# 为什么 kernel 6.19 上路径爆炸很难触发？

## 问题描述

在 `explosion_bad.bpf.o` 中，15 层嵌套 `if` 理论上产生 2^15 = 32,768 条路径。但在 kernel 6.19 上，加载几乎是瞬间完成的。而在 kernel 5.x 上，同样的代码可能触发 `BPF program is too large. Processed N insn` 错误。

## 根本原因：Verifier 的状态剪枝 (State Pruning)

Verifier 的核心工作是对每条执行路径模拟寄存器状态。但 Verifier **不需要**穷举所有路径——如果两条路径在某个汇合点产生了**相同的寄存器状态**，则后续的指令只需分析一次。

这个优化叫 **State Pruning**（状态剪枝）。

### 剪枝是如何工作的

```
路径 A (flags & 1 == true)  ──→  汇合点: sum = SCALAR_VALUE [0, 100]
路径 B (flags & 1 == false) ──→  汇合点: sum = SCALAR_VALUE [0, 100]
                                 ↑
                          两条路径的寄存器状态相同！
                          后续代码只需分析一次。
```

Verifier 维护一个**已访问状态列表** (explored states)。到达每个跳转目标时调用 `is_state_visited()` (verifier.c:19716)：

```
is_state_visited(env, insn_idx)
  ├── 遍历 explored_state(insn_idx) 列表
  ├── 对每个已有状态调用 states_equal()
  │     ├── 比较 curframe (调用栈深度)
  │     ├── 比较 speculative (投机执行标记)
  │     ├── 比较 in_sleepable
  │     ├── 比较 refs (引用追踪)
  │     └── 对每个调用帧: func_states_equal()
  │           ├── regsafe(): 逐寄存器比较 (类型 + 范围 + ID)
  │           └── stacksafe(): 逐栈槽比较
  ├── 如果找到等价状态 → 剪枝！goto process_bpf_exit
  └── 如果没有等价状态 → 继续探索这条新路径
```

### 为什么我们的嵌套 if 被高效剪枝了

看 `explosion_bad.bpf.c` 的实际代码：

```c
u64 sum = 0;
if (flags & 1) { sum += bpf_get_prandom_u32();
    if (flags & 2) { sum += bpf_get_prandom_u32();
        ...
    } else { sum += 1; }
} else { sum += 1; }
```

关键：`sum` 始终是 `SCALAR_VALUE`，`flags` 也是 `SCALAR_VALUE`。

无论走了哪条路径，到达同一个汇合点时：

| 寄存器    | 路径 A (if true)       | 路径 B (if false)      | Verifier 判定 |
| --------- | ---------------------- | ---------------------- | ------------- |
| sum       | SCALAR_VALUE [0, UMAX] | SCALAR_VALUE [0, UMAX] | **相同**      |
| flags     | SCALAR_VALUE [0, UMAX] | SCALAR_VALUE [0, UMAX] | **相同**      |
| 其他 regs | ...                    | ...                    | **相同**      |

**所有寄存器状态都相同** → `states_equal()` 返回 true → **剪枝**。

即使有 15 层嵌套，每层的汇合点都会被剪枝。实际分析的路径数远少于 2^15。

### 什么样的代码真正会路径爆炸

路径爆炸发生在：**不同路径到达同一汇合点时，寄存器状态不同**。

典型的例子是**指针类型的分化**：

```c
void *p;
if (condition) {
    p = bpf_map_lookup_elem(&map1, &key);  // PTR_TO_MAP_VALUE_OR_NULL (map1)
} else {
    p = bpf_map_lookup_elem(&map2, &key);  // PTR_TO_MAP_VALUE_OR_NULL (map2)
}
// 汇合点: 两个 PTR_TO_MAP_VALUE_OR_NULL 指向不同的 map
// Verifier: map1 != map2 → states_equal() 返回 false → 不能剪枝！
```

每层产生不同的指针 ID，Verifier 无法合并 → 路径数指数增长。

### kernel 6.19 的额外优化

1. **Prune Point 标记** (verifier.c:17630)

   第一遍 CFG 构建时，每个条件跳转的目标会被标记为 `prune_point`：

   ```c
   if (e == BRANCH) {
       mark_prune_point(env, w);  // 跳转目标标记为剪枝点
   }
   ```

   第二遍验证时，只在 `prune_point` 处调用 `is_state_visited()`，减少无谓的比较。

2. **SCC (Strongly Connected Component) 感知** (verifier.c:19904)

   对于循环结构，Verifier 在验证前先计算 CFG 的强连通分量 (SCC)。
   进入 SCC 时记录入口状态，退出时传播精度标记 (precision marks)。
   这避免了循环中因为精度不完整而重复分析。

3. **延迟状态创建** (verifier.c:19737)

   ```c
   // bpf progs typically have pruning point every 4 instructions
   // 至少 2 个跳转 + 8 条指令后，才创建新状态
   if (env->jmps_processed - env->prev_jmps_processed >= 2 &&
       env->insn_processed - env->prev_insn_processed >= 8)
       add_new_state = true;
   ```

   避免为短代码段创建过多状态，减少内存和比较开销。

4. **循环内状态节流** (verifier.c:19869)

   ```c
   if (!force_new_state &&
       env->jmps_processed - env->prev_jmps_processed < 20 &&
       env->insn_processed - env->prev_insn_processed < 100)
       add_new_state = false;
   ```

   在循环体内（`sl->state.branches != 0`），限制新状态的创建频率。

## 在老内核 (5.x) 上的行为

kernel 5.x 的 Verifier 没有：

- SCC 感知的精度传播
- 延迟状态创建
- 循环内状态节流

导致相同的嵌套 if 代码在 5.x 上会触发 `BPF_COMPLEXITY_LIMIT_INSNS` (1,000,000)。

## 验证复杂度限制 (verifier.c:195-196)

```c
#define BPF_COMPLEXITY_LIMIT_INSNS    1000000  // 处理指令总数上限
#define BPF_COMPLEXITY_LIMIT_JMP_SEQ 8192      // 跳转序列深度上限
#define BPF_COMPLEXITY_LIMIT_STATES   64        // 非特权用户状态数上限
```

当代码触发限制时：

```
BPF program is too large. Processed 1000001 insn
```

## 关键源码位置

| 函数                  | 文件       | 行号   | 作用                     |
| --------------------- | ---------- | ------ | ------------------------ |
| `mark_prune_point()`  | verifier.c | 17571  | 标记剪枝点               |
| `is_state_visited()`  | verifier.c | 19716  | 检查当前状态是否已被访问 |
| `states_equal()`      | verifier.c | 19477  | 比较两个状态是否等价     |
| `func_states_equal()` | verifier.c | 19450  | 比较单帧状态             |
| `regsafe()`           | (同文件)   | (附近) | 比较单个寄存器安全性     |
| `stacksafe()`         | (同文件)   | (附近) | 比较栈状态安全性         |

## 实验结果：kernel 6.19 上触发路径爆炸的实际尝试

我们在 6.19 上做了三组实验，全部被 Verifier 高效处理：

### 实验 1：标量嵌套 if (explosion_bad.bpf.o)

```c
if (flags & 1) { sum += bpf_get_prandom_u32();
    if (flags & 2) { sum += bpf_get_prandom_u32();
        ... 15 层嵌套 ...
    }
}
```

结果：**加载成功，processed insns ≈ 几百**。

原因：所有路径的寄存器状态都是 `SCALAR_VALUE [0, UMAX]`。`states_equal()` 判定所有路径等价 → 全部剪枝。

### 实验 2：不同 map 的嵌套 if (explosion_unprunable.bpf.o)

```c
if (flags & 1) { v0 = bpf_map_lookup_elem(&map_0, &key); ... }
if (flags & 2) { v1 = bpf_map_lookup_elem(&map_1, &key); ... }
```

25 层、25 个不同 HASH map。理论上每个 map 产生不同的 `map_ptr`。

结果：**加载成功，processed 17 insns**。

原因：即使使用了不同 map，clang `-O2` 仍然将嵌套 if 编译为**扁平结构 + goto 到末尾**（early exit 模式）。
Verifier 只看到线性路径，不存在路径乘法。

### 实验 3：volatile 数组阻止 goto 扁平化

```c
volatile u64 r[N];
if (flags & 1) { r[0] = v ? *v : -1; } else { r[0] = 0; }
```

结果：**加载成功，processed insns ≈ 几百**。

原因：BPF Verifier 不追踪 `volatile` 变量的逐元素状态。`volatile` 是 C 语言层面的约束，Verifier 看到的是同一块栈内存。

### 核心发现

kernel 6.19 的 Verifier 难以被简单的 C 代码触发路径爆炸，原因有三层防御：

1. **编译器优化**：clang `-O2` 将嵌套 if 编译为扁平 goto + early exit，从根源上消除了路径乘法
2. **状态剪枝**：`is_state_visited()` + `states_equal()` 在每个 prune point 比较状态，相同状态直接剪枝
3. **SCC 分析**：强连通分量感知的精度传播，进一步减少循环和复杂路径的分析开销

### 什么样的代码能真正触发路径爆炸？

从原理上，需要同时满足：

1. **编译器不优化**：嵌套结构保留到字节码中（几乎不可能用 C 语言控制 clang）
2. **每条路径产生不同状态**：不同的指针类型 / map_ptr / 精度标记
3. **无 early return**：所有路径都贯穿到程序末尾

在实践中，只有以下场景可能触发：

- 直接编写 BPF 汇编（绕过 clang）
- 极度复杂的 kfunc 调用链（每个 kfunc 改变寄存器状态）
- 动态生成的 BPF 程序（如 bpftrace）

## 总结

| 写法                     | 路径数      | 剪枝效率                 | 建议             |
| ------------------------ | ----------- | ------------------------ | ---------------- |
| 标量嵌套 if (sum += ...) | 2^N (理论)  | 极高 (所有路径状态相同)  | 现代内核都能处理 |
| 不同 map 嵌套 if         | 2^N (理论)  | 极高 (clang 优化为 goto) | 现代内核都能处理 |
| 指针类型分化 if          | 2^N (实际)  | 低 (状态不同)            | 需要子函数拆分   |
| early return 模式        | N (线性)    | 不需要 (无路径乘法)      | 最佳实践         |
| 子函数拆分               | 每函数 2 条 | 高 (函数间独立)          | 推荐方案         |
