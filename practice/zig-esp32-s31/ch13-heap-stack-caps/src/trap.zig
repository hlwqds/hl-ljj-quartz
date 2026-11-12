//! ch13-heap-stack-caps：trap 向量与现场打印。
//!
//! 本章不开中断（MIE 恒为 0，mie 恒为 0），所以这里只会收到**同步异常**：
//! 非法指令、非法访问、对齐错误、ecall。它们在本章都有具体含义：
//!
//!   - 非法访问：踩到未映射区间（PSRAM 窗口没映射就去解引用、或堆块头被写坏）；
//!   - 对齐错误：分配器返回了未对齐的指针，或结构体按 64 位对齐构造；
//!   - ecall：没被使用的让出原语（本章没有调度器）。
//!
//! 入口必须落在 SRAM（`.trap_ram`）：真机实测（2026-11-12）trap 向量在 flash
//! 时，异常投递直接 `rst:0x1a CPU_LOCKUP_RESET`，连 mtvec 里的死循环都执行
//! 不到。链接脚本用 KEEP(*(.trap_ram)) 单独放置它。
//!
//! mcause 的处理口径（ch07 结论，本章复用）：
//!   - 最高位为 1 → 中断；低 6 位是 **CLIC 输入号**，不是规范里的中断编号；
//!   - 最高位为 0 → 同步异常；S31 实测高位还带 CLIC 附加字段
//!     （ecall = 0x3800000b、非法指令 = 0x30000002），所以异常码只能取
//!     `cause & 0x1F`，直接和 11/2 比较会漏。

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

/// 异常码 → 名字（只覆盖本章可能撞上的几个）。
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

/// 打印现场并停机。分配器发现块头损坏时也调它（见 heap.zig 的 verify）。
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    log.line(fmt, args);
    log.raw("panic: halted (wfi)\n");
    while (true) {
        asm volatile ("wfi");
    }
}

/// trap 入口。`linksection(".trap_ram")` + `naked`：不生成序言，自己压 80 字节帧。
///
/// 只保存 caller-saved 与两个 CSR：callee-saved 由 C 调用约定保证
/// （trapDispatch 及其下游会自己保存 s0–s11）。
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
        \\        # 留着完整恢复路径，是为了后续章节复用这个入口。
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

/// trap 入口调用的分发函数。
pub export fn trapDispatch(frame: *TrapFrame) noreturn {
    const cause = asm volatile ("csrr %[d], mcause"
        : [d] "=r" (-> usize),
    );

    if ((cause & 0x8000_0000) != 0) {
        // 中断：低 6 位是 CLIC 输入号，高位的附加字段不进比较。
        const id: usize = cause & 0x3F;
        log.line("trap: interrupt input={d} mepc=0x{x} (MIE was 0; nothing should fire)", .{
            id, frame.mepc,
        });
    } else {
        // 同步异常：CLIC 附加字段在 bit[29:24] 一带，异常码只在低 5 位。
        const code: usize = cause & 0x1F;
        log.line("trap: exception code={d} ({s}) mepc=0x{x} mtval=0x{x}", .{
            code,
            causeName(code),
            frame.mepc,
            asm volatile ("csrr %[d], mtval"
                : [d] "=r" (-> usize),
            ),
        });
    }
    // 帧里没有原始 sp：trapEntry 只压 16 个 GPR + 2 个 CSR（80 字节）。
    // 想看 sp 就把 `csrr t1, sp` 加进汇编，代价是多 4 字节帧。
    log.line("trap: ra=0x{x} a0=0x{x} a1=0x{x}", .{ frame.ra, frame.a0, frame.a1 });
    log.raw("trap: halted (wfi)\n");
    while (true) {
        asm volatile ("wfi");
    }
}
