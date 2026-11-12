//! ch17-ethernet-mac-phy-driver：trap 向量与 panic dump。
//!
//! 本章不开中断（`mstatus.MIE = 0`、`mie = 0`、DMA 中断使能 0），
//! 所以这里只会收到**同步异常**。但向量仍然必须装：以太网驱动里最先
//! 出事的地方永远是“某个寄存器地址写错了一位”，症状是
//! load/store access fault，而不是返回值错误。
//!
//! 两条停机路径：
//!
//!   1. `panic(...)`：软件 panic（自检失败、DMA 软复位超时等）；
//!   2. `trapDispatch(...)`：硬件异常，由 `trapEntry` 压好 80 字节帧后调用。
//!
//! 硬约束（真机实测 2026-11-12）：trap 入口必须放在 SRAM
//! （`.trap_ram`）；放 flash 时异常投递直接 `rst:0x1a CPU_LOCKUP_RESET`，
//! 连 `mtvec` 里的死循环都执行不到。
//!
//! `mcause` 口径（ch07 结论）：最高位 = 1 是中断，此时低 6 位是 CLIC 输入号；
//! 最高位 = 0 是同步异常，S31 的高位仍带 CLIC 附加字段
//! （ecall = 0x3800000b、非法指令 = 0x30000002），异常码只取低 6 位。

const hw = @import("hw.zig");
const log = @import("log.zig");

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

/// 软件 panic：打印原因 + 当前 CSR + 停机。
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    log.line(fmt, args);
    log.line("panic: source=software mcause=0x{x} mepc=0x{x} mtval=0x{x}", .{
        hw.readMcause(), hw.readMepc(), hw.readMtval(),
    });
    log.raw("panic: halted (wfi)\n");
    hw.halt();
}

// ---------------------------------------------------------------------------
// trap 入口：`linksection(".trap_ram")` + naked，自己压 80 字节帧。
// 只保存 caller-saved 与两个 CSR（callee-saved 由 C 调用约定负责）。
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
        \\        # 本章的 trapDispatch 不返回；保留完整恢复路径给后续章节复用。
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

/// 异常/中断分发。本章没有可恢复的异常：打印现场后停机。
pub export fn trapDispatch(frame: *TrapFrame) noreturn {
    const cause = asm volatile ("csrr %[d], mcause"
        : [d] "=r" (-> usize),
    );
    if ((cause & 0x8000_0000) != 0) {
        const input: usize = cause & 0x3F;
        log.line("panic: unexpected interrupt input={d} cause=0x{x} mepc=0x{x}", .{
            input, cause, frame.mepc,
        });
    } else {
        const code: usize = cause & 0x3F;
        log.line("panic: exception code={d} ({s}) cause=0x{x}", .{
            code, causeName(code), cause,
        });
        const mtval = asm volatile ("csrr %[d], mtval"
            : [d] "=r" (-> usize),
        );
        log.line("panic: mepc=0x{x} mtval=0x{x} mstatus=0x{x}", .{
            frame.mepc, mtval, frame.mstatus,
        });
    }
    log.line("panic: ra=0x{x} a0=0x{x} a1=0x{x} a2=0x{x}", .{
        frame.ra, frame.a0, frame.a1, frame.a2,
    });
    log.raw("panic: halted (wfi)\n");
    hw.halt();
}
