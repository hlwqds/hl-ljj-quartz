//! ch14-dual-core-smp-ipi：上下文切换（沿用 ch10/ch11 的两层帧）。
//!
//! 现场仍然由两层组成：
//!
//!   1. **switch 帧（64 字节）**：ra + s0–s11 + 3 个字填充。
//!   2. **trap 帧（80 字节）**：ra、t0–t6、a0–a7、mepc、mstatus + 2 个字填充。
//!
//! 与 ch10–ch13 的唯一结构性差别：**save_slot / target_sp 不能再是全局变量**。
//! 两个核可能在同一时刻各自调用 `switchTo`，一份全局 save_slot 会被另一边
//! 覆盖，恢复出来的 sp 属于别的核 —— 现象是随机的栈跑飞。
//! 本章把它们放进每核的 `PerCpu`（src/smp.zig），用 `mscratch` 找到本核那一份：
//!
//!        csrr t0, mscratch        # t0 = &PerCpu[hart]
//!        lw   t1, 0(t0)           # t1 = save_slot (*usize)
//!        sw   sp, 0(t1)           # 保存旧任务的 sp
//!        lw   sp, 4(t0)           # 切到新任务的 sp
//!
//! `PerCpu` 的前两个字段必须是 `save_slot`、`target_sp`，src/smp.zig 里有
//! `@offsetOf` 断言把这份汇编契约钉死。
//!
//! 另一个真机级教训（ch10–ch12 的 CPU_LOCKUP 根因，ch11 修好）：
//! **不能用 C 约定函数指针去调 `callconv(.naked)` 的 switchRaw**。
//! `@ptrCast` 之后 LLVM 会按 C ABI 给这次调用加序言/尾声（动 sp），
//! 64 字节 switch 帧因此被破坏。正确做法是直接发 `call switchRaw`，
//! 并让 switchRaw 以 `pub export` 出现（符号不被改名）。

const std = @import("std");

/// switch 帧的字节数：13 个寄存器 + 3 个字填充。
pub const switch_frame_bytes: usize = 64;

/// trap 帧的字节数：16 个 GPR + mepc + mstatus + 2 个字填充。
pub const trap_frame_bytes: usize = 80;

/// 浮点变体的总帧长（未实现，仅作为契约）。
pub const fp_switch_frame_bytes: usize = 208;

/// trap 入口压栈后的寄存器视图。字段顺序必须与 `trapEntry` 的偏移一致。
pub const TrapFrame = extern struct {
    ra: usize,
    t0: usize,
    t1: usize,
    t2: usize,
    t3: usize,
    t4: usize,
    t5: usize,
    t6: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
    a6: usize,
    a7: usize,
    mepc: usize,
    mstatus: usize,
    pad: [2]usize,
};

/// 新建任务时手工构造的 64 字节帧。
pub const SwitchFrame = extern struct {
    ra: usize,
    s0: usize,
    s1: usize,
    s2: usize,
    s3: usize,
    s4: usize,
    s5: usize,
    s6: usize,
    s7: usize,
    s8: usize,
    s9: usize,
    s10: usize,
    s11: usize,
    pad: [3]usize,
};

comptime {
    if (@sizeOf(TrapFrame) != trap_frame_bytes) {
        @compileError("TrapFrame 必须是 80 字节（16 GPR + mepc + mstatus + 2 填充）");
    }
    if (@offsetOf(TrapFrame, "mepc") != 64) @compileError("mepc 必须在偏移 64");
    if (@offsetOf(TrapFrame, "mstatus") != 68) @compileError("mstatus 必须在偏移 68");

    if (@sizeOf(SwitchFrame) != switch_frame_bytes) {
        @compileError("SwitchFrame 必须是 64 字节（ra + s0–s11 + 3 填充）");
    }
    if (@offsetOf(SwitchFrame, "s11") != 48) @compileError("s11 必须在偏移 48");
}

// ---------------------------------------------------------------------------
// trap 入口
//
// 由 core0 的 `_start` 与 core1 的 `core1Entry` 各自 `csrw mtvec` 安装
// （MODE=0，直接模式，同一个函数地址）。因为它必须在 core1 起来之前就能
// 取指，链接脚本把它放进 SRAM 的 `.trap_ram` 段。
//
// 只保存 caller-saved 与两个 CSR：callee-saved 由 C 调用约定保证
// （trapDispatch 及其下游函数会自己保存 s0–s11），而真正的切换发生在
// switchRaw 里，那里再补上 64 字节的 callee-saved 帧。
//
// `sp` 用的是**当前任务的栈**：所以 trap 帧天然是每任务一份，
// mepc/mstatus 不需要额外存进 TCB。
// ---------------------------------------------------------------------------
pub export fn trapEntry() linksection(".trap_ram") callconv(.naked) noreturn {
    asm volatile (
        \\        addi    sp, sp, -80
        \\        sw      ra, 0(sp)
        \\        sw      t0, 4(sp)
        \\        sw      t1, 8(sp)
        \\        sw      t2, 12(sp)
        \\        sw      t3, 16(sp)
        \\        sw      t4, 20(sp)
        \\        sw      t5, 24(sp)
        \\        sw      t6, 28(sp)
        \\        sw      a0, 32(sp)
        \\        sw      a1, 36(sp)
        \\        sw      a2, 40(sp)
        \\        sw      a3, 44(sp)
        \\        sw      a4, 48(sp)
        \\        sw      a5, 52(sp)
        \\        sw      a6, 56(sp)
        \\        sw      a7, 60(sp)
        \\
        \\        csrr    t0, mepc
        \\        sw      t0, 64(sp)
        \\        csrr    t0, mstatus
        \\        sw      t0, 68(sp)
        \\
        \\        mv      a0, sp
        \\        call    trapDispatch
        \\
        \\        # 恢复 CSR。此刻 t0 的原值已在 4(sp) 里。
        \\        lw      t0, 64(sp)
        \\        csrw    mepc, t0
        \\        lw      t0, 68(sp)
        \\        csrw    mstatus, t0
        \\
        \\        lw      ra, 0(sp)
        \\        lw      t0, 4(sp)
        \\        lw      t1, 8(sp)
        \\        lw      t2, 12(sp)
        \\        lw      t3, 16(sp)
        \\        lw      t4, 20(sp)
        \\        lw      t5, 24(sp)
        \\        lw      t6, 28(sp)
        \\        lw      a0, 32(sp)
        \\        lw      a1, 36(sp)
        \\        lw      a2, 40(sp)
        \\        lw      a3, 44(sp)
        \\        lw      a4, 48(sp)
        \\        lw      a5, 52(sp)
        \\        lw      a6, 56(sp)
        \\        lw      a7, 60(sp)
        \\
        \\        addi    sp, sp, 80
        \\        mret
    );
}

// ---------------------------------------------------------------------------
// switchRaw / switchTo
// ---------------------------------------------------------------------------

/// 保存 callee-saved、换 sp、恢复 callee-saved。返回时已经在新任务的栈上。
///
/// `PerCpu` 字段偏移（src/smp.zig 用 @offsetOf 断言）：
///   0 → save_slot（*usize）    4 → target_sp（usize）
pub export fn switchRaw() callconv(.naked) void {
    asm volatile (
        \\        addi    sp, sp, -64
        \\        sw      ra, 0(sp)
        \\        sw      s0, 4(sp)
        \\        sw      s1, 8(sp)
        \\        sw      s2, 12(sp)
        \\        sw      s3, 16(sp)
        \\        sw      s4, 20(sp)
        \\        sw      s5, 24(sp)
        \\        sw      s6, 28(sp)
        \\        sw      s7, 32(sp)
        \\        sw      s8, 36(sp)
        \\        sw      s9, 40(sp)
        \\        sw      s10, 44(sp)
        \\        sw      s11, 48(sp)
        \\
        \\        csrr    t0, mscratch         # t0 = &PerCpu[本核]
        \\        lw      t1, 0(t0)            # t1 = save_slot（指向旧任务的 sp 字段）
        \\        sw      sp, 0(t1)            # 旧 sp 落盘
        \\        lw      sp, 4(t0)            # sp = 新任务保存的 sp
        \\
        \\        lw      ra, 0(sp)
        \\        lw      s0, 4(sp)
        \\        lw      s1, 8(sp)
        \\        lw      s2, 12(sp)
        \\        lw      s3, 16(sp)
        \\        lw      s4, 20(sp)
        \\        lw      s5, 24(sp)
        \\        lw      s6, 28(sp)
        \\        lw      s7, 32(sp)
        \\        lw      s8, 36(sp)
        \\        lw      s9, 40(sp)
        \\        lw      s10, 44(sp)
        \\        lw      s11, 48(sp)
        \\        addi    sp, sp, 64
        \\        ret
    );
}

/// 保存点通过**本核**的 PerCpu 传递（见 src/smp.zig 的 `beginSwitch`）。
pub fn switchTo(save_slot: *usize, new_sp: usize) void {
    const smp = @import("smp.zig");
    smp.prepareSwitch(save_slot, new_sp);
    // 直接发 `call`：不经函数指针，LLVM 不会加 C ABI 的序言/尾声。
    // switchRaw 返回时 sp 已经是“新任务”的，控制流落在对方的调用点。
    asm volatile ("call switchRaw"
        :
        :
        : .{});
}

/// 新任务的启动桩：switchRaw 的 `ret` 落到这里。
///
/// s0 = 任务入口地址，s1 = 唯一参数（TCB 指针）。入口声明为 noreturn；
/// 如果它真的返回，`ebreak` 会让调试器停在这里，而不是静默跑飞。
///
/// **必须在这里打开 MIE**：新建任务没有 trap 帧，不会走 `mret`，也就没有
/// 任何“MPIE → MIE”的自动恢复。切换发生在 trap 上下文里（trap 入口已把
/// MIE 清 0），如果这里不 `csrsi`，新任务会带着 MIE=0 一直跑下去，
/// 永远收不到 tick 与 IPI。被抢占过的任务不走这里：它恢复后逐层返回
/// 自己的 trapEntry，由 `mret` 把 MPIE 写回 MIE。
pub export fn taskStart() callconv(.naked) noreturn {
    asm volatile (
        \\        # 中断阈值也必须回到“全放行”。trap 上下文里 MIE=0 只能挡住
        \\        # 同级以下的投递路径中的一部分；CLIC 的 mintthresh（CSR 0x347）
        \\        # 才是真正的门。新任务没有 trap 帧、不会走 mret，
        \\        # 所以这两件事都要自己做：
        \\        #   mstatus.MIE = 1，mintthresh = 0x1f（(0<<5)|0x1f，只挡 0 级）。
        \\        # 本工程从不在任务里抬高阈值；若将来引入“屏蔽某级”的临界区，
        \\        # 阈值必须像 mstatus 一样进每任务上下文，不能在这里写死。
        \\        li      t0, 0x1f
        \\        csrw    0x347, t0
        \\        csrsi   mstatus, 0x8
        \\        mv      a0, s1
        \\        jalr    s0
        \\        ebreak
        \\1:      j       1b
    );
}

/// 在任务栈顶构造第一帧，返回它对应的 sp。
///
/// 新任务的栈布局（从高到低）：
///   [ 栈顶 16 对齐 ][ 64 字节 switch 帧 ] ← 返回值
/// switchRaw 恢复这帧后 `ret` 到 taskStart，sp = 栈顶。
pub fn initTaskStack(stack: []const u8, entry: usize, arg: usize) usize {
    const top = (@intFromPtr(stack.ptr) + stack.len) & ~@as(usize, 15);
    // std.debug.assert 在 ReleaseSmall 里退化成 unreachable，不拉 panic 运行时。
    std.debug.assert(top - @intFromPtr(stack.ptr) >= switch_frame_bytes);

    const frame_addr = top - switch_frame_bytes;
    const frame: *SwitchFrame = @ptrFromInt(frame_addr);
    frame.* = std.mem.zeroes(SwitchFrame);
    frame.ra = @intFromPtr(&taskStart);
    frame.s0 = entry;
    frame.s1 = arg;
    return frame_addr;
}
