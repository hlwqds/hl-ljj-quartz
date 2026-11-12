//! ch12-sync-primitives-ipc：原子指令与自旋锁（RISC-V A 扩展）+ 关中断临界区。
//!
//! 本章一共三种“互斥”手段，各有它唯一正确的使用场合：
//!
//! | 手段                        | 挡住谁                       | 代价                     |
//! | --------------------------- | ---------------------------- | ------------------------ |
//! | `csrci mstatus, 8`（关中断）| 同核上的中断与抢占           | 关多久就丢多久的实时性   |
//! | `lr.w`/`sc.w` 自旋（本文件）| 另一个 hart 的并发读改写     | 自旋烧电、需要缓存一致性 |
//! | 互斥量（mutex.zig）         | 上层任务（可阻塞、可继承）   | 上下文切换，微秒级       |
//!
//! **单核上只用自旋锁是错的。** 持有者被 tick 抢占后，自旋者在同一个 hart 上
//! 永远等不到它释放——死锁，而且是“关着中断死锁”，连串口都打不出来。
//! 所以本文件的 `SpinLock.acquire` 先 `irqSave` 抬高中断闸门，再做 CAS，
//! 这与 IDF 自己的 `spinlock_acquire` 完全同构：
//! `components/esp_hw_support/include/spinlock.h:74` 里第一件事就是
//! `rv_utils_set_intlevel_regval(RVHAL_EXCM_LEVEL_CLIC)`，之后才
//! `esp_cpu_compare_and_set(&lock->owner, SPINLOCK_FREE, core_owner_id)`。
//!
//! CAS 的循环形状照抄 IDF 的 `rv_utils_compare_and_set`
//! （`components/riscv/include/riscv/rv_utils.h:513`）：
//!
//! ```text
//! cas: lr.w  t0, (a)      # 独占读，同时在该地址上建立 reservation
//!      bne  t0, expect, fail
//!      sc.w  t1, new, (a) # 只有 reservation 还在时才会写入；否则 t1 != 0
//!      bnez t1, cas       # 失败就整段重来（必须重读，不能直接重写）
//! fail:
//! ```
//!
//! `sc.w` 失败不表示出错，只表示“状态已经变了，你手上的读已经过期”。
//! 唯一正确的反应是**从头再读一次**，这正是循环回到 `lr.w` 的原因。
//!
//! 内存序：`lr.w`/`sc.w`/`amoswap.w`/`amoadd.w` 不带 `.aq`/`.rl` 时只保证
//! “该地址自身的原子性”，不保证前后的普通访存不被重排。本章用两类手段：
//!   - 获取/释放语义的指令后缀 `.aq`（acquire）/ `.rl`（release）；
//!   - 显式 `fence rw, rw`（编译器层面用 `asm volatile` 阻止跨越）。

const std = @import("std");
const sched = @import("sched.zig");

/// 自旋上限。单核 + 关中断的自旋锁第一次 CAS 必然成功，
/// 所以这个上限永远不会被触发；它存在只是为了让“真出问题”时能打印
/// 而不是静默挂死（关着中断的死循环连串口都不吐字）。
const max_spins: u32 = 100_000;

/// 一个字大小的自旋锁。必须 4 字节对齐：`lr.w`/`sc.w` 只接受对齐地址。
pub const SpinLock = struct {
    locked: u32 align(4) = 0,
};

/// LR/SC 重试次数与成功加锁次数。真机上单核恒为“一次成功”，
/// 打印它是为了让“没有竞争”这个结论可验证，而不是靠猜。
pub var retries: u32 = 0;
pub var acquisitions: u32 = 0;
pub var giveups: u32 = 0;

/// 单次比较交换：`lr.w` + `sc.w`，失败返回 false（不重试）。
///
/// 输出用 `=&r`（early clobber）：`lr.w` 会先写 old，而 inputs 可能被分配到
/// 同一个物理寄存器，不加 `=&` 编译器有权复用，生成的代码就是错的。
fn tryCas(p: *volatile u32, expect: u32, replace: u32) bool {
    var old: u32 = 0;
    var err: u32 = 0;
    asm volatile (
        \\  lr.w   %[o], (%[a])
        \\  bne    %[o], %[e], 2f
        \\  sc.w   %[r], %[n], (%[a])
        \\  bnez   %[r], 2f
        \\2:
        : [o] "=&r" (old),
          [r] "=&r" (err),
        : [a] "r" (@intFromPtr(p)),
          [e] "r" (expect),
          [n] "r" (replace),
        : .{ .memory = true }
    );
    return old == expect and err == 0;
}

/// 取锁：先关中断，再 CAS 自旋。返回进入前的 `mstatus`，
/// 必须原样交给 `release`。
pub fn acquire(l: *SpinLock) usize {
    const old = sched.irqSave();
    var guard: u32 = 0;
    while (!tryCas(&l.locked, 0, 1)) {
        retries += 1;
        guard += 1;
        if (guard >= max_spins) {
            // 走到这里说明“关着中断还在等一个不会释放的锁”。
            // 继续自旋只会让板子静默卡死，所以记一笔并放行，
            // 让上层逻辑暴露问题（这是诊断，不是修复）。
            giveups += 1;
            break;
        }
    }
    acquisitions += 1;
    return old;
}

/// 放锁：先把锁字写回 0，再恢复中断状态。
///
/// 顺序不能反：先开中断再放锁，会在“锁还持有”的窗口里被 tick 打断，
/// 而下一个任务可能正好在等这把锁——它自旋到超时也等不到我们放锁。
///
/// **内存模型的边界要写清楚**：`asm volatile` 本身只保证“这段汇编不被删除、
/// 不被复制、不会跨它做纯计算的重排”，它**不声明**自己读写内存，
/// 所以单靠 `volatile`，编译器仍有权把 `l.locked = 0` 挪到 `fence` 之前。
/// 真正补上这一刀的是 clobber 里的 `.memory = true`
/// （Zig 0.17 各架构的 `Clobbers` 结构都有这个字段）：
/// 它告诉编译器“这条 asm 读写任意内存”，于是前后的访存都不能跨过它。
/// 单 hart + 关中断的本章即使漏掉它也不会出错（没有第二个 hart 能观察），
/// 但这种“因为没并发所以现在对”的代码，一上 SMP 就会变成偶发故障。
pub fn release(l: *SpinLock, old_mstatus: usize) void {
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
    l.locked = 0;
    sched.irqRestore(old_mstatus);
}

/// `amoswap.w.aq`：不可分割的“读旧值 + 写新值”。等价于一次 ACE 的交换，
/// 不需要重试循环，代价是它不能表达“只在旧值等于某个数时才写”。
pub fn xchg(p: *volatile u32, v: u32) u32 {
    var old: u32 = 0;
    asm volatile ("amoswap.w.aq %[o], %[v], (%[p])"
        : [o] "=r" (old),
        : [v] "r" (v),
          [p] "r" (@intFromPtr(p)),
    );
    return old;
}

/// `amoadd.w.aq`：原子加一并返回旧值。计数器用它最省事，
/// 不需要 lr/sc 的重试循环。
pub fn addOne(p: *volatile u32) u32 {
    var old: u32 = 0;
    asm volatile ("amoadd.w.aq %[o], %[v], (%[p])"
        : [o] "=r" (old),
        : [v] "r" (@as(u32, 1)),
          [p] "r" (@intFromPtr(p)),
    );
    return old + 1;
}

/// 不关中断的“纯自旋锁”。**只在确定不会被抢占的场合用**（例如中断
/// 已经关闭的短临界区，或 SMP 且各 hart 都有独立进度时）。
/// 本章的演示任务不用它——它们用 `acquire`。
pub fn acquireRaw(l: *SpinLock) void {
    while (!tryCas(&l.locked, 0, 1)) {
        retries += 1;
        asm volatile ("nop");
    }
    acquisitions += 1;
}

pub fn releaseRaw(l: *SpinLock) void {
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
    l.locked = 0;
}
