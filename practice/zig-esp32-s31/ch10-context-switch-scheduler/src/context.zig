//! ch10-context-switch-scheduler：上下文切换的两种帧。
//!
//! 本章只有整数任务，所以现场由两层组成：
//!
//!   1. **switch 帧（64 字节）**：ra + s0–s11 + 3 个字填充。
//!      13 个寄存器是 52 字节，按 psABI 的 16 字节栈对齐向上取整到 64。
//!      它由 `switchRaw` 压在当前栈上，`sp` 就是任务的“硬件上下文锚点”。
//!
//!   2. **trap 帧（80 字节）**：ra、t0–t6、a0–a7、mepc、mstatus + 2 个字填充。
//!      16 个 GPR 是 caller-saved 的全部；两个 CSR 让每个任务记住
//!      “从哪条指令继续、陷入前的中断状态是什么”。
//!
//! 这两层的分工：
//!   - 64 字节决定“任务之间换不换得动”；
//!   - 80 字节决定“换回来以后从哪儿继续”。
//!
//! 浮点任务需要 **208 字节**的变体（64 + f0–f31(128) + fcsr(4) + 12 填充），
//! 原因见 README 的「FPU 边界」一节；本工程不使用浮点，所以没有实现它。
//! S31 的 `SOC_CPU_HAS_FPU_EXT_ILL_BUG=1` 使“懒保存”（mstatus.FS=0 触发
//! 非法指令、再在异常里保存）不可行，因此真要上 FP 时必须无条件保存全部
//! 32 个 f 寄存器，而不是只保存 ABI 里的 callee-saved 那一半。

const std = @import("std");

/// switch 帧的字节数：13 个寄存器 + 3 个字填充。
pub const switch_frame_bytes: usize = 64;

/// trap 帧的字节数：16 个 GPR + mepc + mstatus + 2 个字填充。
pub const trap_frame_bytes: usize = 80;

/// 浮点变体的总帧长（未实现，仅作为后续章节的契约）。
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
// 由 `_start` 用 `csrw mtvec, trapEntry` 安装（MODE=0，直接模式）。
// mtvec.BASE 必须 4 字节对齐；链接脚本用 `.text.trap` 段保证这一点。
//
// 只保存 caller-saved 与两个 CSR：callee-saved 由 C 调用约定保证
// （trapDispatch 及其下游函数会自己保存 s0–s11），而真正的切换发生在
// switchRaw 里，那里再补上 64 字节的 callee-saved 帧。
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
        \\        # 恢复 CSR。此刻 t0 已不再需要保存原值（它在 4(sp) 里）。
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
// switchRaw
//
// naked 函数不能带参数，所以两个 sp 通过模块级变量传递：
//   - switch_save_slot 指向“旧任务的 sp 字段”，出栈前把当前 sp 写进去；
//   - switch_target_sp 是新任务保存的 sp。
//
// 之所以写进 `*old_sp` 而不是一个临时全局，是因为任务恢复时会把控制流
// 送回它自己的 switchRaw 调用点；如果把 sp 存在单一全局里，后一次切换
// 会覆盖前一次的值，恢复出来的 sp 就属于别的任务。
// ---------------------------------------------------------------------------
export var switch_save_slot: *usize = undefined;
export var switch_target_sp: usize = 0;

pub fn switchTo(save_slot: *usize, new_sp: usize) void {
    // Zig 0.17 禁止直接调用 naked 函数；经函数指针调用是官方认可的出口。
    const raw: *const fn () callconv(.c) void = @ptrCast(&switchRaw);
    switch_save_slot = save_slot;
    switch_target_sp = new_sp;
    raw();
}

/// 保存 callee-saved、换 sp、恢复 callee-saved。返回时已经在新任务的栈上。
fn switchRaw() callconv(.naked) void {
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
        \\        la      t0, switch_save_slot
        \\        lw      t0, 0(t0)
        \\        sw      sp, 0(t0)
        \\
        \\        la      t0, switch_target_sp
        \\        lw      sp, 0(t0)
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

/// 新任务的启动桩：switchRaw 的 `ret` 落到这里。
///
/// s0 = 任务入口地址，s1 = 唯一参数（TCB 指针）。入口声明为 noreturn；
/// 如果它真的返回，`ebreak` 会让调试器停在这里，而不是静默跑飞。
pub export fn taskStart() callconv(.naked) noreturn {
    asm volatile (
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
