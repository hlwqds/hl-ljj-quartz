//! ch15-observability-testing-stability：trap 向量、panic dump 与“故意崩一次”。
//!
//! 本章不开中断（`mstatus.MIE = 0`、`mie = 0`），所以这里只会收到**同步异常**。
//! 但仍然要装 `mtvec`：自检失败、断言升级、以及本章演示的“故意非法指令”
//! 都必须能打印现场，而不是让芯片静默复位。
//!
//! 两条停机路径：
//!
//!   1. `panic(...)`：软件 panic。没有 trap 帧，打印调用点给的字符串 +
//!      `mcause/mepc`（此时它们是 0/0）+ trace 尾部，然后 `wfi`。
//!   2. `trapDispatch(...)`：硬件异常。由 `trapEntry` 压好 80 字节帧后调用，
//!      打印 `mcause/mepc/mtval/ra/a0..a2` + trace 尾部，然后 `wfi`。
//!
//! `trip()` 是第 2 条路径的触发器：执行一条全零指令（RISC-V 定义为非法指令）。
//! 它存在的意义是**证明 panic 路径真的能打印**——一个从未运行过的 dump
//! 代码与没有 dump 没有区别。
//!
//! 硬约束（真机实测 2026-11-12）：trap 入口必须放在 SRAM（`.trap_ram`）。
//! 放 flash 时异常投递直接 `rst:0x1a CPU_LOCKUP_RESET`，连 `mtvec` 里的
//! 死循环都执行不到（ch06 复现）。链接脚本用 `KEEP(*(.trap_ram))` 单独放置。
//!
//! `mcause` 口径（ch07 结论，本章复用）：
//!   - 最高位 = 1 → 中断；低 6 位是 **CLIC 输入号**，不是规范里的中断编号；
//!   - 最高位 = 0 → 同步异常；S31 实测高位带 CLIC 附加字段
//!     （ecall = 0x3800000b、非法指令 = 0x30000002），异常码只能取低 6 位。

const hw = @import("hw.zig");
const log = @import("log.zig");
const trace = @import("trace.zig");

/// trap 入口压栈后的寄存器视图（80 字节，与汇编偏移逐字对应）。
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

comptime {
    if (@sizeOf(TrapFrame) != 80) @compileError("TrapFrame 必须是 80 字节");
    if (@offsetOf(TrapFrame, "mepc") != 64) @compileError("mepc 必须在偏移 64");
    if (@offsetOf(TrapFrame, "mstatus") != 68) @compileError("mstatus 必须在偏移 68");
}

fn causeName(code: usize) []const u8 {
    return switch (code) {
        0 => "instruction address misaligned",
        1 => "instruction access fault",
        2 => "illegal instruction",
        3 => "breakpoint",
        4 => "load address misaligned",
        5 => "load access fault",
        6 => "store address misaligned",
        7 => "store access fault",
        11 => "environment call (m-mode)",
        else => "unknown",
    };
}

/// 打印 trace 环里最新的 `limit` 条（时间顺序）。panic dump 的核心内容：
/// 崩溃前发生了什么，比崩溃时寄存器是什么更难重建。
pub fn dumpTrace(limit: u32) void {
    const ring = &trace.g_ring;
    const n = ring.count();
    if (n == 0) {
        log.line("dump: trace empty (pushed=0)", .{});
        return;
    }
    const first = if (n > limit) n - limit else 0;
    var buf: [96]u8 = undefined;
    var i: u32 = first;
    while (i < n) : (i += 1) {
        if (ring.at(i)) |rec| {
            log.line("{s}", .{trace.formatRecord(rec, &buf)});
        }
    }
    log.line("dump: trace shown={d}/{d} pushed={d} dropped={d}", .{
        n - first, n, ring.pushed, ring.dropped,
    });
}

/// 软件 panic：打印一行原因 + 当前 `mcause/mepc` + trace 尾部，然后停机。
/// 自检失败、watchdog 升级时调用。
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    log.line(fmt, args);
    log.line("panic: source=software mcause=0x{x} mepc=0x{x} mtval=0x{x}", .{
        hw.readMcause(),
        hw.readMepc(),
        hw.readMtval(),
    });
    dumpTrace(8);
    log.raw("panic: halted (wfi)\n");
    hw.halt();
}

/// 故意执行一条全零指令。RISC-V 规定 0x0000 为非法指令，
/// 会以 `mcause = 2`（带 CLIC 高位）进入 `trapEntry`。
pub fn trip() noreturn {
    log.raw("panic: injecting illegal instruction 0x00000000\n");
    trace.g_ring.push(.{
        .t_us = hw.nowUs(),
        .tag = .panic,
        .a = 2,
        .b = 0,
    });
    asm volatile (".word 0x00000000" ::: .{});
    // 如果异常没有发生（例如工具链把 .word 解释成了别的东西），
    // 至少不要继续跑飞：停在这里，让“没有 dump”本身成为证据。
    log.raw("panic: illegal instruction did not trap\n");
    hw.halt();
}

// ---------------------------------------------------------------------------
// trap 入口
//
// `linksection(".trap_ram")` + `naked`：不生成序言，自己压 80 字节帧。
// 只保存 caller-saved 与两个 CSR：callee-saved 由 C 调用约定保证
// （trapDispatch 及其下游会自己保存 s0–s11）。
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
        \\        # 本章的 trapDispatch 不会返回（没有可恢复的异常）。
        \\        # 保留完整恢复路径，方便后续章节复用这个入口。
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
        \\        addi    sp, sp, 80
        \\        mret
    );
}

/// 异常/中断分发。这里不再区分“可恢复”与“不可恢复”：本章没有可恢复的异常。
pub export fn trapDispatch(frame: *TrapFrame) noreturn {
    const cause = hw.readMcause();
    if ((cause & 0x8000_0000) != 0) {
        // 中断：低 6 位是 CLIC 输入号。本章 MIE = 0，任何中断都是意外。
        const input: usize = cause & 0x3F;
        log.line("panic: unexpected interrupt input={d} cause=0x{x} mepc=0x{x}", .{
            input, cause, frame.mepc,
        });
    } else {
        // 同步异常：CLIC 附加字段在高位，异常码只在低 6 位。
        const code: usize = cause & 0x3F;
        log.line("panic: exception code={d} ({s}) cause=0x{x}", .{
            code, causeName(code), cause,
        });
        log.line("panic: mepc=0x{x} mtval=0x{x} mstatus=0x{x}", .{
            frame.mepc, hw.readMtval(), frame.mstatus,
        });
    }
    log.line("panic: ra=0x{x} a0=0x{x} a1=0x{x} a2=0x{x}", .{
        frame.ra, frame.a0, frame.a1, frame.a2,
    });
    dumpTrace(8);
    log.raw("panic: halted (wfi)\n");
    hw.halt();
}
