//! ch06-gpio-uart-log：trap 向量与 panic 路径。
//!
//! 这里做的事情很少，但每一件都必须精确：
//!
//!   1. `install()` 把 `mtvec` 指向 `trapVector`，MODE = 0（直接模式），
//!      即“任何异常都跳到这一个地址”。本章不配 CLIC 的向量模式，也不打开
//!      任何中断（`mie = 0`、`mstatus.MIE = 0`），所以这个向量只承接**异常**。
//!   2. `trapVector` 是 naked 函数：把 mcause / mepc / ra / mtval / sp 抓进
//!      参数寄存器后跳进普通函数 `trapReport`。抓 `ra` 必须在任何 `call`
//!      之前完成——一旦调用，`ra` 就被这一层覆盖了。
//!   3. `trapReport` 打印一行诊断并**停机**。没有栈回溯、不尝试恢复：
//!      裸机上的“panic”首先是“保住现场”，其次才是“多打几行”。
//!
//! 为什么不做 unwinder：RISC-V 的栈回溯要靠 `.eh_frame` 或帧指针链，而本工程
//! 既没有异常表（`-fno-exceptions` 语义的 freestanding 构建），也没有强制
//! 帧指针；`ra` 与 `sp` 是唯一**一定**存在且**一定**正确的两个现场标记。
//! 后续若有调试器（JTAG/OpenOCD），由它读栈——这比在固件里猜帧布局可靠。

const uart = @import("uart.zig");
const log = @import("log.zig");

/// 把 `mtvec` 指向本工程的 trap 向量。
///
/// `mtvec` 的低 2 位是 MODE：0 = 直接（所有异常/中断都进 BASE），
/// 因此 BASE 必须 4 字节对齐。`trapVector` 放在 `.text.entry`，
/// 链接脚本保证它在 `ALIGN(16)` 之后，满足要求；这里仍然检查一次，
/// 因为“链接脚本被改坏”是真实会发生的故障，而报错比静默跑飞便宜。
pub fn install() void {
    const addr: usize = @intFromPtr(&trapVector);
    if (addr & 0x3 != 0) {
        fatal("mtvec 基址未 4 字节对齐（检查 .text.entry 的放置）");
    }
    asm volatile ("csrw mtvec, %[v]"
        :
        : [v] "r" (addr));
}

/// trap 向量：MODE=0 直接模式，异常入口。
///
/// 汇编只做“搬移 + 跳转”，不保存现场：这里不可能返回，所以不需要
/// 保存/恢复任何寄存器。这正是 panic 路径与中断路径的区别所在。
export fn trapVector() linksection(".text.entry") callconv(.naked) noreturn {
    asm volatile (
        \\        csrr    a0, mcause          # 异常原因（bit31=1 表示中断）
        \\        csrr    a1, mepc            # 触发异常的指令地址
        \\        mv      a2, ra              # 触发点的返回地址（call 之前抓）
        \\        csrr    a3, mtval           # 附加信息（非法指令的编码/出错地址）
        \\        mv      a4, sp              # 当时的栈指针
        \\        call    trapReport          # 普通函数：打印 + 停机
        \\1:
        \\        wfi
        \\        j       1b
    );
}

fn causeName(cause: u32) [*:0]const u8 {
    // mcause 的低位是异常/中断编号，最高位区分“中断”与“异常”。
    // 编号表来自 RISC-V 特权级规范（非注入中断部分）。
    if ((cause & 0x8000_0000) != 0) return "interrupt (本章未开中断，不该出现)";
    return switch (cause) {
        0 => "instruction address misaligned",
        1 => "instruction access fault",
        2 => "illegal instruction",
        3 => "breakpoint",
        4 => "load address misaligned",
        5 => "load access fault",
        6 => "store/AMO address misaligned",
        7 => "store/AMO access fault",
        11 => "environment call from M-mode",
        else => "reserved / vendor-specific",
    };
}

/// 异常报告。签名顺序与 `trapVector` 里 a0..a4 的填充顺序一一对应。
export fn trapReport(cause: u32, mepc: u32, ra: u32, mtval: u32, sp: u32) noreturn {
    log.msg(.err, "---- trap ----");
    uart.puts("cause : ");
    uart.puts(causeName(cause));
    uart.putc('\n');
    uart.putHex32("mcause", cause);
    uart.putHex32("mepc  ", mepc);
    uart.putHex32("ra    ", ra);
    uart.putHex32("mtval ", mtval);
    uart.putHex32("sp    ", sp);
    log.msg(.err, "halted: 需要复位（EN）或重新烧录");
    halt();
}

/// 软件侧的统一停机点：打印一行 `[P] ...` 然后 `wfi` 死循环。
/// 不返回调用者——本工程里“无法继续”只有这一种处置方式。
pub fn fatal(comptime text: [:0]const u8) noreturn {
    log.msg(.err, text);
    halt();
}

/// 停机：`wfi` 让核进入等待，`j` 保证不会跑飞。
/// 中断全关，所以 `wfi` 实际上就是“到此为止”，直到复位。
pub fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

/// trap 演示：执行一条**全零指令**。
///
/// RISC-V 规范规定“全零指令永久保留为非法指令”，所以它一定触发
/// `mcause = 2`（illegal instruction），并把 `mepc` 指到这条指令本身。
/// 这是本章唯一一个“可以主动制造、且后果可预期”的异常——用它验证
/// `mtvec` 真的被设置了、`trapReport` 真的能打印。
///
/// 代价是**板子会停在那里**，必须按 EN 复位。因此它只挂在串口命令 `t`
/// 上，不随启动自动执行。
pub fn trapDemo() noreturn {
    log.msg(.warn, "trap demo: 即将执行 0x00000000（非法指令），板子会停机，需复位");
    asm volatile (".4byte 0x00000000");
    // 不会到达：上面那条指令必然触发异常并进入 trapVector。
    // 仍然写一个显式停机而不是 `unreachable`：`unreachable` 在 ReleaseSmall 下
    // 是“优化器可以假设不会发生”，一旦假设错了就是未定义行为；
    // 而 `halt()` 是确定的 wfi 死循环。
    halt();
}
