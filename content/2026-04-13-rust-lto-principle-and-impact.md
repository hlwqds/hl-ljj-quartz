---
title: Rust LTO 原理与影响 — 编译慢的隐形杀手
date: 2026-04-13 00:00:00
tags: [rust, lto, llvm, performance, compilation]
description: LTO（链接时优化）是 Rust release 模式编译慢的主要原因，本文从原理到实测，讲清楚 LTO 的机制、收益、代价和优化策略
---

# Rust LTO 原理与影响 — 编译慢的隐形杀手

## 一句话结论

**Rust release 模式编译慢，很多时候不是代码多，而是 LTO 在做跨编译单元的全局优化。** 在 LLVM 18→21 升级过程中，LTO 开销暴涨了 4-16 倍。理解 LTO 的机制，才能在编译速度和运行时性能之间做出正确取舍。

## 什么是 LTO

LTO（Link-Time Optimization，链接时优化）是编译器的一种优化策略。传统编译流程中，每个编译单元（源文件/crate）独立编译为目标文件，链接器只负责拼接，看不到跨编译单元的优化机会：

```
传统流程：
  src1.rs → LLVM IR → opt → codegen → obj1.o ─┐
  src2.rs → LLVM IR → opt → codegen → obj2.o ─┤→ linker → binary
  src3.rs → LLVM IR → opt → codegen → obj3.o ─┘
  （每个文件独立优化，看不到跨文件内联、死代码消除等机会）
```

LTO 改变了这个流程，把 LLVM IR 保留到链接阶段，由链接器做全局优化：

```
LTO 流程：
  src1.rs → LLVM IR (bitcode) ─┐
  src2.rs → LLVM IR (bitcode) ─┤→ 合并 → 全局 opt → codegen → binary
  src3.rs → LLVM IR (bitcode) ─┘
  （所有代码一起优化，可以跨模块内联、消除死代码、优化调用链）
```

### LTO 能做什么

| 优化 | 说明 |
|------|------|
| 跨模块内联 | 函数调用跨越 crate 边界时，LTO 可以内联它 |
| 死代码消除 | 识别并删除未被使用的跨 crate 函数和数据 |
| 过程间优化 | 跨模块常量传播、循环优化、调用链简化 |
| devirtualization | 将虚函数调用转为直接调用 |

这些优化在单编译单元内编译器也能做，但 LTO 的优势是**全局视角**——能看到整个程序的所有代码。

## Rust 中的 LTO

### 三种模式

| 模式 | 配置 | 说明 |
|------|------|------|
| 关闭 | `lto = false` 或不设置 | 各 crate 独立编译，链接器只拼接 |
| ThinLTO | `lto = "thin"` | 只交换函数摘要，按需导入 IR，编译较快 |
| Fat LTO | `lto = true` 或 `lto = "fat"` | 合并所有 IR 到一个巨大单元，优化最彻底但最慢 |

### Rust 默认设置

```toml
# Rust 默认的 release profile
[profile.release]
opt-level = 3
debug = false
lto = false          # 默认关闭
codegen-units = 16   # 并行编译单元数
```

**Rust 默认不开 LTO。** 但很多项目会在 `Cargo.toml` 中显式启用：

```toml
[profile.release]
lto = "thin"    # 或 lto = true
```

### ThinLTO vs Fat LTO

```
Fat LTO：所有 IR 合并成一个巨大单元 → 单线程处理 → 最慢
ThinLTO：各 crate 生成摘要 → 并行分析 → 按需导入 IR → 较快
```

| 对比 | ThinLTO | Fat LTO |
|------|---------|---------|
| 编译速度 | 较快 | 最慢 |
| 优化效果 | 接近 Fat | 最优 |
| 内存占用 | 较低 | 很高 |
| 并行度 | 高 | 低（最终合并是单线程） |

**建议：如果需要 LTO，优先用 ThinLTO。**

### codegen-units 与 LTO 的关系

`codegen-units` 控制并行编译的粒度，默认 16。**开启 LTO 时，codegen-units 会被自动降为 1**（Fat LTO）或保持较高（ThinLTO），这意味着：

- LTO 关闭 + codegen-units=16 → 16 路并行编译，快
- Fat LTO → 本质上 1 路编译，慢
- ThinLTO → 并行度较高，折中

## LTO 的收益

LTO 的主要收益是**运行时性能提升**和**产物体积缩小**：

| 项目 | 编译时间 | 运行时性能 | 产物体积 |
|------|----------|-----------|----------|
| LTO off | 基准 | 基准 | 基准 |
| ThinLTO | +50-80% | +5-10% | -20-40% |
| Fat LTO | +100-200% | +5-17% | -30-65% |

> 数据来源：社区多个项目的实测平均值

运行时性能提升主要来自跨 crate 内联和死代码消除。对于库/框架类项目（函数调用多、接口抽象多），LTO 收益更明显。对于计算密集型项目，收益较小。

## LTO 的代价

### 编译时间暴增

以下是在编译 Suricata（含 Rust app-layer 组件）时的实测数据：

**不同 rustc 版本的编译时间（`cargo build --release`）：**

| rustc 版本 | LLVM 版本 | 编译时间 | 相对倍数 |
|------------|-----------|----------|----------|
| 1.89.0 | LLVM 18 | ~50s | 1x |
| 1.91.0 | LLVM 19 | ~62s | 1.2x |
| 1.94.1 | LLVM 21 | >200s | >4x |

**`perf record` 分析 1.94.1 编译过程：**

| 阶段 | CPU 占比 | 说明 |
|------|----------|------|
| **LTO 链接优化** | **145.2%** | 跨 crate 全局优化，多核并行所以 >100% |
| rustc 编译（类型检查、MIR 生成等） | 41.7% | Rust 编译器前端+中端 |
| LLVM opt（代码生成优化） | 41.1% | LLVM IR 优化 pass |
| cc1（C 组件编译） | 13.0% | Suricata 的 C 代码部分 |
| ld（最终链接） | 4.6% | 系统链接器 |

**LTO 占了编译总 CPU 时间的 60% 以上。**

### 内存占用增大

LTO 需要将所有 crate 的 LLVM IR 加载到内存中做全局分析。大型项目的 LTO 阶段内存占用可能达到数 GB，在内存不足时会触发 swap，进一步拖慢编译。

### 产物调试困难

开启 LTO 后，函数可能被内联、合并、重排，调试时断点位置和源码行号可能不匹配。

## 实测分析：如何定位 LTO 开销

### 步骤 1：生成编译 profile

```bash
# 编译时生成编译时间信息
cargo build --release -Z timings

# 查看哪个 crate 编译最慢
cat target/release/cargo-timing.html
```

`-Z timings` 需要 nightly 工具链：

```bash
rustup install nightly
rustup override set nightly
cargo build --release -Z timings
```

### 步骤 2：perf 采样

```bash
# 降低 perf 权限限制
sudo sysctl -w kernel.perf_event_paranoid=-1

# 记录编译过程
perf record -F 99 -g -o perf.data -- cargo build --release

# 查看各阶段 CPU 占比
perf report --stdio --no-children -g none
```

关注 `lto`、`opt`、`rustc` 三个进程的占比。如果 `lto` 占比很高，说明 LTO 是瓶颈。

### 步骤 3：关闭 LTO 对比

```bash
# 关闭 LTO 编译
RUSTFLAGS="-C lto=off" cargo build --release

# 对比时间
time RUSTFLAGS="-C lto=off" cargo build --release
time cargo build --release
```

如果关闭 LTO 后编译时间大幅缩短，确认 LTO 是瓶颈。

## 优化策略

### 1. 关闭 LTO（开发阶段推荐）

```bash
RUSTFLAGS="-C lto=off" cargo build --release
```

或在 `Cargo.toml` 中：

```toml
[profile.release]
lto = false
```

**适用场景：** 开发调试、CI 快速验证、对运行时性能不敏感的场景

### 2. 使用 ThinLTO 代替 Fat LTO

```toml
[profile.release]
lto = "thin"
```

编译速度比 Fat LTO 快很多，优化效果接近。

### 3. 锁定 rustc 版本

本项目实测发现 LLVM 18→21 的 LTO 开销差异巨大：

```bash
cd your-project
rustup install 1.89.0
rustup override set 1.89.0
```

或在项目中创建 `rust-toolchain.toml` 锁定版本：

```toml
[toolchain]
channel = "1.89.0"
```

### 4. 增加 codegen-units（仅 LTO 关闭时有效）

```toml
[profile.release]
codegen-units = 32   # 默认 16，增大可提高并行度
```

**注意：** 开启 LTO 时增大会导致优化效果下降，不建议同时使用。

### 5. 使用 mold 或 lld 链接器

```toml
# .cargo/config.toml
[target.x86_64-unknown-linux-gnu]
linker = "clang"
rustflags = ["-C", "link-arg=-fuse-ld=mold"]
```

mold 比 GNU ld 快 5-10 倍，lld 快 2-3 倍。

### 6. 分级 profile（推荐）

为不同场景定义不同的 profile：

```toml
# 开发用：快速编译
[profile.dev-release]
inherits = "release"
lto = false
codegen-units = 32
opt-level = 2        # 比 3 快很多，性能损失约 5%

# 生产用：最佳性能
[profile.release]
lto = "thin"
codegen-units = 1
opt-level = 3
```

编译时选择：

```bash
# 开发
cargo build --profile dev-release

# 生产
cargo build --release
```

## 总结建议

| 场景 | LTO 策略 | 理由 |
|------|----------|------|
| 开发调试 | 关闭 | 编译速度优先 |
| CI 测试 | 关闭或 ThinLTO | 平衡速度和覆盖率 |
| 生产发布 | ThinLTO | 性能收益明显，编译代价可接受 |
| 嵌入式/大小敏感 | Fat LTO | 产物体积最小 |
| 库/框架项目 | ThinLTO | 跨 crate 内联收益大 |
| 计算密集型 | 关闭 | 内部计算已足够优化 |

核心原则：**编译速度和运行时性能是 trade-off，不要盲目开 LTO。** 用数据说话——先 `perf record` 看瓶颈在哪，再决定是否开启。

## 参考

- [Rust Performance Book - Build Configuration](https://nnethercote.github.io/perf-book/build-configuration.html)
- [Why is the Rust compiler so slow?](https://sharnoff.io/blog/why-rust-compiler-slow)
- [Rust Compiler Performance Survey 2025 Results](https://blog.rust-lang.org/2025/09/10/rust-compiler-performance-survey-2025-results.html)
- [LLVM Link Time Optimization](https://llvm.org/docs/LinkTimeOptimization.html)
