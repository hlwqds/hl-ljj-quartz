# Kernel BTF 对特殊类型的验证路径分析

## 背景

当 BPF 程序在 map value 中使用 `bpf_list_head` 时，内核在 BTF 加载阶段就会进行严格的验证。如果验证失败，`BPF_BTF_LOAD` 系统调用返回 `-EINVAL`，程序无法加载。

本文基于 kernel 6.19 源码 (`kernel/bpf/btf.c`, `kernel/bpf/verifier.c`) 分析完整的验证路径。

## 一个常见错误

```c
// ❌ 缺少 btf_decl_tag，BTF 加载直接 -EINVAL
struct map_value {
    struct bpf_spin_lock lock;
    struct bpf_list_head head;  // 编译通过，加载失败!
};
```

错误日志：
```
libbpf: BTF loading error: -EINVAL
```

没有更多提示，错误发生在 `btf_parse_struct_metas` 阶段。

## 正确写法

```c
struct node {
    u32 value;
    struct bpf_list_node node;
};

struct map_value {
    struct bpf_spin_lock lock;
    struct bpf_list_head head __attribute__((btf_decl_tag("contains:node:node")));
    //                             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //                             格式: "contains:<value_type>:<node_field_name>"
};
```

## 为什么需要 decl_tag

C 语言没有泛型。内核看到 `struct bpf_list_head head` 时，无法知道这个链表存储的元素类型。

`btf_decl_tag` 通过 BTF 的 `BTF_KIND_DECL_TAG` 类型在编译时嵌入元数据，告诉内核：

- **value_type**：链表元素是 `struct node`
- **node_field_name**：`struct node` 中用于链接的字段名是 `node`

有了这个信息，内核可以做到：
1. **类型安全**：`bpf_list_push_back` 只接受 `struct node` 类型的元素
2. **所有权环检测**：防止 A→B→C→A 的环形所有权导致内存泄漏
3. **偏移量计算**：知道 `bpf_list_node` 在 value struct 中的精确偏移

## 完整验证路径

以下是 `bpftool prog load` 触发的完整内核验证链：

```
用户空间: bpftool prog load xxx.o /sys/fs/bpf/xxx
  │
  ▼
内核: bpf_prog_load (kernel/bpf/syscall.c)
  │
  ├─ bpf_obj_get_info_by_fd -> 加载 prog BTF
  │
  ▼
btf_parse (kernel/bpf/btf.c:5793)
  │
  ├─ 1. btf_parse_hdr()          ← 验证 BTF 头部格式
  ├─ 2. btf_parse_str_sec()      ← 验证字符串表
  ├─ 3. btf_parse_type_sec()     ← 验证所有类型定义
  ├─ 4. btf_check_type_tags()    ← 验证 type tag 链
  │
  ├─ 5. btf_parse_struct_metas() ← ★ 关键步骤：解析特殊 struct 字段
  │     │
  │     ├─ 扫描 BTF 中所有 STRUCT 类型
  │     ├─ 查找 alloc_obj_fields[] 中定义的特殊类型:
  │     │   "bpf_spin_lock", "bpf_list_head", "bpf_list_node",
  │     │   "bpf_rb_root", "bpf_rb_node", "bpf_refcount"
  │     │
  │     ├─ 对于每个包含特殊字段的 struct，调用 btf_parse_fields()
  │     │   │
  │     │   ├─ btf_find_field()        ← 遍历 struct 成员，识别特殊字段
  │     │   │   │
  │     │   │   ├─ 发现 bpf_spin_lock → 标记 BPF_SPIN_LOCK
  │     │   │   │
  │     │   │   └─ 发现 bpf_list_head → 调用 btf_find_graph_root()
  │     │   │       │
  │     │   │       ├─ btf_find_decl_tag_value(btf, pt, comp_idx, "contains:")
  │     │   │       │   │
  │     │   │       │   ├─ 找到 tag → 解析 "contains:node:node"
  │     │   │       │   │   ├─ value_type = "node"
  │     │   │       │   │   └─ node_field_name = "node"
  │     │   │       │   │
  │     │   │       │   └─ 找不到 tag → return -EINVAL ★ 失败点!
  │     │   │       │
  │     │   │       ├─ btf_find_by_name_kind(btf, "node", BTF_KIND_STRUCT)
  │     │   │       │   └─ 找不到 value_type → return -ENOENT
  │     │   │       │
  │     │   │       └─ 记录 info.graph_root.value_btf_id 和 node_name
  │     │   │
  │     │   ├─ btf_parse_list_head()    ← 验证 value struct 中的 node 字段
  │     │   │   └─ btf_parse_graph_root()
  │     │   │       ├─ 遍历 value_type 的成员
  │     │   │       ├─ 找到 node_field_name 的成员
  │     │   │       ├─ 验证其类型是 "bpf_list_node"
  │     │   │       ├─ 验证偏移量对齐 (offset % __alignof__(bpf_list_node) == 0)
  │     │   │       └─ 记录 graph_root.node_offset
  │     │   │
  │     │   └─ 检查 spin_lock 配对:
  │     │       if (has bpf_list_head && !has bpf_spin_lock)
  │     │           return -EINVAL  ★ bpf_list_head 必须配 bpf_spin_lock
  │     │
  │     └─ btf_check_and_fixup_fields()  ← 所有权环检测
  │         │
  │         ├─ 找到 value_type 的 struct_meta
  │         ├─ 检查是否有 BPF_GRAPH_NODE (bpf_list_node / bpf_rb_node)
  │         └─ 遍历所有权边，检测环:
  │             A (root) → B (root+node) → C (node) → ... → A? → -EINVAL
  │
  └─ 6. 后续: verifier 使用 struct_meta 做 runtime 检查
        │
        ├─ bpf_list_push_back 时 (详见下节「spin_lock 持有检查」):
        │   验证 node 的类型匹配 bpf_list_head 声明的 value_type
        │   验证持有 spin_lock
        │   转移所有权标记 (owning_ref → non-owning_ref)
        │
        └─ bpf_obj_new 时:
            验证 prog BTF 存在 (否则 "requires prog BTF")
            通过 BTF type ID 确定分配大小

## spin_lock 持有检查 (verifier 阶段)

当 BPF 程序调用 `bpf_list_push_back(&v->head, &n->node)` 时，verifier 如何确认已持有正确的 spin_lock？

答案：**不检查 spin_lock 的偏移量，而是通过 allocation identity 匹配。**

### 为什么不能只检查"有没有锁"

```c
// ❌ 假设只检查"持有任意锁"就能通过:
bpf_spin_lock(&other_map->lock);  // 锁了另一个 map 的 lock
bpf_list_push_back(&v->head, &n->node);  // 操作 v 的 list_head
// 两个不同的 map value，锁不匹配！
```

### Verifier 的匹配机制

Verifier 为每个 map value / BPF 堆分配维护一个唯一 `(id, ptr)` 对：
- **id**: `reg->id`，verifier 为每个寄存器分配的唯一标识
- **ptr**: `map_ptr`（map value）或 `btf`（BPF 堆分配）

### bpf_spin_lock() — 记录锁状态

```
bpf_spin_lock(&v->lock) 被调用时，verifier 执行 (verifier.c:8440):
  │
  ├─ 1. 从 reg 的 btf_record 获取 spin_lock_off
  │     spin_lock_off = rec->spin_lock_off;  // BTF 加载时已记录，值为 0
  │
  ├─ 2. 验证参数偏移量指向 spin_lock 成员
  │     if (spin_lock_off != val + reg->off)  → -EINVAL
  │
  ├─ 3. 检查是否已有其他 bpf_spin_lock 被持有
  │     find_lock_state(state, REF_TYPE_LOCK, 0, NULL)
  │     └─ 有 → "Locking two bpf_spin_locks are not allowed"
  │
  └─ 4. 记录锁状态到 active_locks
        acquire_lock_state(env, insn_idx, REF_TYPE_LOCK, reg->id, reg->map_ptr)
        //                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        //                       key = (id=reg->id, ptr=reg->map_ptr)
        //                       保存的是整个 allocation 的身份，不是 lock 的偏移
```

### bpf_list_push_back() — 检查锁状态

```
bpf_list_push_back(&v->head, &n->node) 被调用时，verifier 执行:
  │
  ├─ check_kfunc_args()
  │   └─ __process_kf_arg_ptr_to_graph_root()  // 处理 R1 = &v->head
  │       │
  │       ├─ 验证 head 偏移量是常量
  │       ├─ 在 btf_record 中找到 bpf_list_head 字段
  │       │
  │       └─ check_reg_allocation_locked(env, reg)  // ★ 检查锁
  │           │
  │           ├─ 从 R1 的 reg 获取 (id, ptr):
  │           │   ptr = reg->map_ptr;  // v 所在的 map
  │           │   id  = reg->id;       // v 的唯一标识
  │           │
  │           ├─ env->cur_state->active_locks 为空?
  │           │   └─ 是 → return -EINVAL (没持有任何锁)
  │           │
  │           └─ find_lock_state(state, REF_TYPE_LOCK_MASK, id, ptr)
  │               │
  │               ├─ 遍历 active_locks 链表
  │               ├─ 匹配 s->id == id && s->ptr == ptr
  │               │   即: lock 时的 (id, ptr) == 现在 head 时的 (id, ptr)
  │               │
  │               ├─ 匹配 → return 0 ✓ (同一个 allocation 的锁)
  │               └─ 不匹配 → -EINVAL "held lock and object are not in the same allocation"
  │
  └─ 所有权转移
      ref_convert_owning_non_owning(env, release_ref_obj_id)
      release_reference(env, release_ref_obj_id)
```

### bpf_spin_unlock() — 释放锁状态

```
bpf_spin_unlock(&v->lock) 被调用时 (verifier.c:8494):
  │
  ├─ active_locks 为空? → "unlock without taking a lock"
  │
  ├─ find_lock_state(cur, REF_TYPE_LOCK, reg->id, ptr)
  │   └─ 匹配 (id, ptr)? → 不匹配则 "unlock of different lock"
  │
  ├─ 检查解锁顺序: reg->id == cur->active_lock_id
  │   └─ 不匹配 → "unlock cannot be out of order"
  │
  └─ release_lock_state(cur, type, id, ptr)  // 从 active_locks 移除
```

### 关键设计

| 问题 | 答案 |
|------|------|
| Verifier 怎么知道哪个 spin_lock 保护哪个 list_head? | 不需要知道。只要 lock 和 head 在**同一个 allocation**（同一个 map value 或同一个 bpf_obj_new 分配），就认为匹配 |
| 为什么用 (id, ptr) 而不是 lock 偏移量? | 因为一个 allocation 只允许一个 bpf_spin_lock（verifier.c:8462 检查），所以匹配 allocation 等价于匹配 lock |
| 锁了另一个 map 的 lock 能操作这个 map 的 list 吗? | 不能。(id, ptr) 不同，find_lock_state 返回 NULL |
| bpf_spin_lock 能嵌套吗? | 不能。第二个 bpf_spin_lock 会触发 "Locking two bpf_spin_locks are not allowed" |
```

## 源码关键函数索引

### BTF 加载阶段 (kernel/bpf/btf.c)

| 函数 | 行号 | 作用 |
|------|------|------|
| `btf_parse` | 5793 | BTF 加载入口 |
| `btf_parse_struct_metas` | 5569 | 扫描 struct 中的特殊字段 |
| `btf_parse_fields` | 3945 | 解析单个 struct 的特殊字段 |
| `btf_find_graph_root` | 3444 | 读取 decl_tag，解析 contains: |
| `btf_parse_graph_root` | 3875 | 验证 value struct 中的 node 字段 |
| `btf_parse_list_head` | 3919 | bpf_list_head 专用解析 |
| `btf_check_and_fixup_fields` | 4076 | spin_lock 配对 + 所有权环检测 |

### Verifier 阶段 (kernel/bpf/verifier.c)

| 函数 | 行号 | 作用 |
|------|------|------|
| `check_reg_allocation_locked` | 12826 | 检查 list/rb 操作时是否持有对应的 spin_lock |
| `find_lock_state` | 1639 | 在 active_locks 中查找匹配的锁状态 |
| `acquire_lock_state` | (辅助) | bpf_spin_lock 时记录锁状态 |
| `release_lock_state` | (辅助) | bpf_spin_unlock 时释放锁状态 |
| `__process_kf_arg_ptr_to_graph_root` | 12990 | 处理 push_back/pop 等操作的 graph root 参数验证 |
| `process_kf_arg_ptr_to_list_node` | (辅助) | 验证 push_back 的 node 参数类型匹配 |

## btf_decl_tag 的 BTF 编码

编译后，`__attribute__((btf_decl_tag("contains:node:node")))` 会被 clang 编码为 BTF 类型：

```
// bpftool btf dump 输出 (简化)
struct map_value size=24 vlen=2
    lock type_id=13 bits_offset=0
    head type_id=14 bits_offset=64

DECL_TAG "contains:node:node" type_id=14 component_idx=1
//                     ^^^^^^^^^^^^^^^^^^  ^^^^^^^^  ^^^^^^^^^^^^^
//                     tag 内容            指向 head  head 是第 1 个成员 (0-indexed)
```

`BTF_KIND_DECL_TAG` 是 BTF 的一种 type kind，内核在 `btf_find_decl_tag_value` 中解析它。

## 相关 commit

| Commit | 引入版本 | 说明 |
|--------|---------|------|
| `f0c5941ff5b2` | v6.2 | bpf: Support bpf_list_head in map values |
| `807b1ae84cb2` | v6.1 | bpf: Add btf_decl_tag kind |

## BPF 特殊类型与 decl_tag 要求一览

BPF map value 中可以嵌入多种内核特殊类型，但并非所有类型都需要 `btf_decl_tag`。

### 需要 decl_tag 的类型（容器类型）

| 类型 | 注解格式 | 说明 |
|------|---------|------|
| `bpf_list_head` | `btf_decl_tag("contains:<value_type>:<node_field>")` | 链表头，声明存储的元素类型 |
| `bpf_rb_root` | `btf_decl_tag("contains:<value_type>:<node_field>")` | 红黑树根，声明存储的元素类型 |

这两个类型走相同的解析路径 (`btf_find_graph_root` → `btf_find_decl_tag_value`)，都需要 `contains:` 前缀的 decl_tag。

```c
// bpf_list_head 示例
struct node {
    u32 value;
    struct bpf_list_node node;
};

struct map_value {
    struct bpf_spin_lock lock;
    struct bpf_list_head head
        __attribute__((btf_decl_tag("contains:node:node")));
    // contains:<struct_name>:<bpf_list_node_field_name>
};

// bpf_rb_root 示例
struct tree_node {
    u64 key;
    struct bpf_rb_node rb;
};

struct map_value {
    struct bpf_spin_lock lock;
    struct bpf_rb_root root
        __attribute__((btf_decl_tag("contains:tree_node:rb")));
};
```

### 不需要 decl_tag 的类型

| 类型 | 原因 |
|------|------|
| `bpf_spin_lock` | 纯粹的锁，无需额外类型信息 |
| `bpf_res_spin_lock` | 可重入锁变体，同上 |
| `bpf_list_node` | 被 `contains:` 引用，自身不需要注解 |
| `bpf_rb_node` | 同上 |
| `bpf_timer` | 回调函数通过 `bpf_timer_set_callback()` 运行时注册 |
| `bpf_wq` | workqueue，回调运行时注册 |
| `bpf_task_work` | task work，回调运行时注册 |
| `bpf_refcount` | 纯引用计数，无需类型参数 |
| `bpf_kptr` | 类型信息通过指针类型本身推断（`__kptr` 标记） |

**判断依据**：只有**容器类型**（`bpf_list_head`、`bpf_rb_root`）需要 decl_tag，因为内核必须知道容器里装什么类型，才能在 push/insert 时做类型检查和所有权追踪。其他类型要么是被引用的叶子节点（`bpf_list_node`），要么是独立工具（锁、定时器），要么在运行时绑定回调。

## 调试技巧

```bash
# 开启 libbpf 调试日志，看到 BTF 加载失败的详细信息
LIBBPF_LOG_LEVEL=debug sudo bpftool prog load xxx.o /sys/fs/bpf/xxx

# 查看编译产物中的 decl_tag
bpftool btf dump file xxx.o format c | grep -A2 DECL_TAG

# 查看内核中 bpf_list_head 的定义
bpftool btf dump file /sys/kernel/btf/vmlinux format c | grep -A5 'struct bpf_list_head'

# 二分定位 BTF 加载问题: 逐步添加特殊类型，找到导致 -EINVAL 的那个
```
