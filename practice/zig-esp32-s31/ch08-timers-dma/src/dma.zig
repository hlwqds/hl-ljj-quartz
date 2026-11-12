//! ch08-timers-dma：AHB-GDMA 的内存到内存搬运（描述符链 + 轮询完成）。
//!
//! S31 上有三套 DMA：AHB-DMA（`0x20343000`）、AXI-DMA（`0x20348000`）、
//! 低功耗域的 LP-AHB-DMA（`0x20819000`）。本章用 AHB 这一套，因为它
//! 够简单：**5 个通道对（pair）**，每对天然带一个 RX（写内存）和一个 TX
//! （读内存）通道，通道 0..4 的寄存器块步长 0x100。
//!
//! 内存到内存（M2M）的模型：
//!
//!   源缓冲 --TX 通道读描述符--> 内部数据通路 --RX 通道写描述符--> 目的缓冲
//!
//! 两个通道都“连到内存”而不是某个外设：RX 侧要把
//! `IN_CONF0.MEM_TRANS_EN` 置 1，并把 IN/OUT 的 `PERI_SEL` 都指向**同一个**
//! M2M 触发号，硬件才知道这一对是在自己搬自己。
//!
//! 关键常量与出处（IDF v6.1）：
//!   - 基址 `DR_REG_AHB_DMA_BASE = 0x20343000`：`register/soc/reg_base.h`
//!   - 寄存器偏移与位域：`register/soc/ahb_dma_reg.h`
//!   - 描述符 12 字节、4 字节对齐、dw0 字段：
//!     `components/esp_hal_dma/include/hal/dma_types.h`
//!       size[11:0] / length[23:12] / suc_eof[30] / owner[31]
//!   - 5 个 pair、描述符对齐 4B、PSRAM 支持、PSRAM burst ≤128B：
//!     `components/esp_hal_dma/esp32s31/include/hal/gdma_ll.h`
//!   - M2M 触发号候选掩码 `AHB_DMA_LL_M2M_FREE_PERIPH_ID_MASK = 0x8200`
//!     （bit9 与 bit15 → 触发号 9 和 15），同文件
//!   - M2M 的连线语义（mem_trans_en 与 peri_sel）：
//!     `components/esp_hal_dma/esp32s31/include/hal/ahb_dma_ll.h`
//!       `ahb_dma_ll_rx_connect_to_mem` / `ahb_dma_ll_tx_connect_to_mem`
//!   - 启动顺序 RX 先、TX 后：
//!     `components/esp_driver_dma/src/async_memcpy_gdma.c`
//!       （`try_start_pending_transaction`：`gdma_start(rx)` 再 `gdma_start(tx)`）
//!
//! 本章只做**轮询**：开始搬运后轮询 `IN_INT_RAW.DONE`，超时用 SYSTIMER 计。
//! DMA 完成中断需要 ch07 的中断路由，属于「待真机验证」。
//!
//! 与 cache 的关系：本工程的缓冲都在内部 SRAM（链接脚本只映射 SRAM）。
//! 若把缓冲换到 PSRAM，必须先按 cache line 做写回/无效，否则 CPU 看到的
//! 是 cache 里的旧数据、DMA 看到的是内存里的新数据——见正文 8.7。

const systimer = @import("systimer.zig");

const dma_base: usize = 0x2034_3000;
const clkrst_base: usize = 0x2058_7000;

/// HP_SYS_CLKRST_AHB_PDMA_CTRL0（偏移 0x7c）：bit0 SYS_CLK_EN（复位值 1），
/// bit1 RST_EN（写 1 再写 0 复位整个 AHB-DMA）。
const clkrst_ahb_pdma_ctrl0: usize = clkrst_base + 0x7c;
const pdma_sys_clk_en: u32 = 1 << 0;
const pdma_rst_en: u32 = 1 << 1;

/// 通道对编号。S31 的 AHB-DMA 有 5 对（0..4），本章固定用 0 号。
pub const pair: usize = 0;

/// 通道寄存器块 = base + pair * 0x100。
const ch: usize = dma_base + pair * 0x100;

// RX（IN）方向
const reg_in_int_raw: usize = ch + 0x00;
const reg_in_int_ena: usize = ch + 0x08;
const reg_in_int_clr: usize = ch + 0x0c;
const reg_in_conf0: usize = ch + 0x100;
const reg_in_link: usize = ch + 0x110;
const reg_in_link_addr: usize = ch + 0x114;
const reg_in_suc_eof_des: usize = ch + 0x11c;
const reg_in_err_eof_des: usize = ch + 0x120;
const reg_in_done_des: usize = ch + 0x124;
const reg_in_peri_sel: usize = ch + 0x138;

// TX（OUT）方向
const reg_out_int_raw: usize = ch + 0x50;
const reg_out_int_clr: usize = ch + 0x5c;
const reg_out_conf0: usize = ch + 0x180;
const reg_out_link: usize = ch + 0x190;
const reg_out_link_addr: usize = ch + 0x194;
const reg_out_done_des: usize = ch + 0x1a4;
const reg_out_peri_sel: usize = ch + 0x1b8;

// IN_CONF0
const in_rst: u32 = 1 << 0;
const in_dscr_burst: u32 = 1 << 2;
const in_mem_trans_en: u32 = 1 << 4;
const in_burst_mode_shift: u5 = 6;

// OUT_CONF0
const out_rst: u32 = 1 << 0;
const out_auto_wrback: u32 = 1 << 2;
const out_eof_mode: u32 = 1 << 3;
const out_dscr_burst: u32 = 1 << 4;
const out_burst_mode_shift: u5 = 8;

// LINK
const in_link_start: u32 = 1 << 2;
const in_link_stop: u32 = 1 << 1;
const out_link_start: u32 = 1 << 1;
const out_link_stop: u32 = 1 << 0;

// 中断位（IN/OUT 同构）
const int_done: u32 = 1 << 0;
const int_suc_eof: u32 = 1 << 1;
const int_err_eof: u32 = 1 << 2;
const int_dscr_err: u32 = 1 << 3;
const int_clear_all: u32 = 0x3F;

/// M2M 触发号。`AHB_DMA_LL_M2M_FREE_PERIPH_ID_MASK = 0x8200` 说明候选是
/// 9 和 15；本章取 9。若真机上搬运不动，先确认这个号是否被别的外设占用。
/// （待真机验证）
const m2m_trigger_id: u32 = 9;

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

/// 硬件描述符：12 字节、4 字节对齐。
///
/// 字段布局与 `dma_descriptor_t` 完全一致，用 u32 而不是 Zig 的 packed
/// bitfield，是为了让“写 dw0”这件事在源码里逐位可见：
///
///   dw0 = size | length << 12 | suc_eof << 30 | owner << 31
///
/// TX 描述符由 CPU 填好、owner 置 1（归 DMA）交给硬件；RX 描述符同样先归
/// DMA，搬完后硬件把实际字节数回写到 length、把 owner 清 0 还给 CPU。
pub const Descriptor = extern struct {
    dw0: u32,
    buffer: u32,
    next: u32,
};

comptime {
    if (@sizeOf(Descriptor) != 12) @compileError("DMA 描述符必须是 12 字节");
    if (@alignOf(Descriptor) != 4) @compileError("DMA 描述符必须 4 字节对齐");
}

/// 单个描述符能挂的最大字节数：size 字段 12 位，上限 4095。
/// 这里取 1024，一是 4 的整数倍、二是让 4 段链覆盖 4 KiB 的演示规模。
pub const chunk_bytes: usize = 1024;
pub const max_chunks: usize = 4;
pub const max_bytes: usize = chunk_bytes * max_chunks;

/// 静态描述符链。放 .bss（`_start` 清零），生命周期覆盖整个应用——
/// 绝不能在函数栈上建描述符后启动 DMA 就返回。
var tx_chain: [max_chunks]Descriptor align(4) = undefined;
var rx_chain: [max_chunks]Descriptor align(4) = undefined;

pub const Error = error{
    /// 长度为 0。
    Empty,
    /// 超过 max_bytes 或单个描述符上限。
    TooLarge,
    /// 源/目的地址或长度没有按 4 字节对齐。
    Misaligned,
    /// DMA 报告描述符错误或总线错误。
    DmaError,
    /// 等完成超时（默认 100 ms）。
    Timeout,
};

pub const Report = struct {
    /// RX / TX 的 INT_RAW 快照：bit0 DONE、bit1 SUC_EOF。
    in_raw: u32,
    out_raw: u32,
    /// 硬件回写的“最后一个成功描述符”地址。
    rx_done_desc: u32,
    tx_done_desc: u32,
    rx_eof_desc: u32,
    /// 实际使用的描述符个数（1..max_chunks）。
    chunks: u32,
    /// 从启动到观察到 DONE 的 SYSTIMER tick 数（16 MHz，62.5 ns/tick）。
    elapsed_ticks: u64,
};

/// 使能/复位 AHB-DMA 的模块时钟。
///
/// SYS_CLK_EN 复位值就是 1，这里仍然显式写一遍：如果 bootloader 或别的
/// 代码把它关了，所有通道寄存器都会读回 0，看起来像“DMA 坏了”。
pub fn init() void {
    const c = reg(clkrst_ahb_pdma_ctrl0);
    c.* |= pdma_sys_clk_en;
    c.* |= pdma_rst_en;
    c.* &= ~pdma_rst_en;
}

/// 复位一个通道的 FSM 与 FIFO 指针（CONF0 的 RST 位写 1 再写 0）。
fn resetChannels() void {
    reg(reg_in_conf0).* = in_rst;
    reg(reg_in_conf0).* = 0;
    reg(reg_out_conf0).* = out_rst;
    reg(reg_out_conf0).* = 0;
}

/// 把 `len` 字节切成若干描述符，返回描述符个数。
///
/// 链表是**单向**的：最后一个的 `next = 0`，`suc_eof = 1` 告诉 RX 侧
/// “到此为止”。TX 侧的 `suc_eof` 同样必需，否则 RX 收不到 EOF，
/// `SUC_EOF` 位不会置起（本章的完成判定用 DONE，但 EOF 是链尾的语义）。
fn buildChain(chain: []Descriptor, addr: u32, len: usize) u32 {
    var off: usize = 0;
    var n: usize = 0;
    while (off < len) : (n += 1) {
        const remain = len - off;
        const chunk: usize = if (remain > chunk_bytes) chunk_bytes else remain;
        const size: u32 = @intCast(chunk);
        const last = off + chunk >= len;

        chain[n].dw0 = size | (size << 12) |
            (@as(u32, @intFromBool(last)) << 30) |
            (1 << 31); // owner = DMA
        chain[n].buffer = addr + @as(u32, @intCast(off));
        chain[n].next = if (last) 0 else @intCast(@intFromPtr(&chain[n + 1]));

        off += chunk;
    }

    return @intCast(n);
}

fn addrOf(ptr: anytype) u32 {
    return @intCast(@intFromPtr(ptr));
}

/// 内存到内存复制。
///
/// 前置条件（运行时检查，违反返回 `error.Misaligned`）：
///   - `dst.len == src.len`，元素都是 u8；
///   - 两个指针 4 字节对齐，长度是 4 的倍数（AHB-DMA 的内部访存粒度）；
///   - 长度 ≤ 4096，且每段 ≤ 1024。
///
/// 完成后返回寄存器快照；数据正确性由调用者自己比对（本模块不读缓冲，
/// 免得把一次 DMA 搬运变成一次额外的 CPU 拷贝）。
pub fn copy(dst: []u8, src: []const u8) Error!Report {
    if (dst.len != src.len) return Error.Misaligned;
    const len = src.len;
    if (len == 0) return Error.Empty;
    if (len > max_bytes) return Error.TooLarge;

    const src_addr = addrOf(src.ptr);
    const dst_addr = addrOf(dst.ptr);
    if ((src_addr & 0x3) != 0 or (dst_addr & 0x3) != 0) return Error.Misaligned;
    if ((len & 0x3) != 0) return Error.Misaligned;

    // 1) 停掉上一次可能残留的传输，再复位两个通道。
    reg(reg_in_link).* = in_link_stop;
    reg(reg_out_link).* = out_link_stop;
    resetChannels();

    // 2) 配 CONF0。
    //    RX：mem_trans_en=1（不是从外设收，而是从内存读）；
    //        burst 模式 0 = single（最保守，先证明链路通）。
    //    IN_CONF1 里还有 EOF 与回写相关的策略位（IDF 的 async_memcpy 会设
    //    owner_check / auto_update_desc / eof_till_data_popped）。本章保持复位值，
    //    先用“DONE + CPU 比对”验证最小闭环；若真机出现尾部字节不一致，
    //    下一步就是打开 eof_till_data_popped（字段以 ahb_dma_reg.h 为准，
    //    待真机验证）。
    reg(reg_in_conf0).* = in_mem_trans_en;

    //    TX：eof_mode=1 表示“数据全部推出去才算 EOF”；auto_wrback 关掉，
    //        描述符由 CPU 预填，不需要硬件回写 length。
    reg(reg_out_conf0).* = out_eof_mode;

    // 3) 两边都连到同一个 M2M 触发号。
    reg(reg_in_peri_sel).* = m2m_trigger_id;
    reg(reg_out_peri_sel).* = m2m_trigger_id;

    // 4) 建链并写链表头。
    const chunks = buildChain(&rx_chain, dst_addr, len);
    _ = buildChain(&tx_chain, src_addr, len);
    reg(reg_in_link_addr).* = addrOf(&rx_chain[0]);
    reg(reg_out_link_addr).* = addrOf(&tx_chain[0]);

    // 5) 清中断原始位（上次传输可能留下 DONE/EOF）。
    reg(reg_in_int_clr).* = int_clear_all;
    reg(reg_out_int_clr).* = int_clear_all;

    // 6) 启动：先 RX 后 TX（与 IDF async_memcpy 的顺序一致）。
    //    RX 先就位，TX 推过来的数据才不会无处可去。
    const start_ticks = systimer.ticks();
    reg(reg_in_link).* = in_link_start;
    reg(reg_out_link).* = out_link_start;

    // 7) 轮询 RX 的 DONE，最多等 100 ms。
    const deadline = systimer.deadlineAfterUs(100_000);
    while (true) {
        const raw = reg(reg_in_int_raw).*;
        if (raw & int_done != 0) break;
        if (raw & (int_err_eof | int_dscr_err) != 0) {
            reg(reg_in_link).* = in_link_stop;
            reg(reg_out_link).* = out_link_stop;
            return Error.DmaError;
        }
        if (systimer.reached(deadline)) {
            reg(reg_in_link).* = in_link_stop;
            reg(reg_out_link).* = out_link_stop;
            return Error.Timeout;
        }
    }
    const elapsed = systimer.ticks() -% start_ticks;

    const in_raw = reg(reg_in_int_raw).*;
    const out_raw = reg(reg_out_int_raw).*;

    reg(reg_in_link).* = in_link_stop;
    reg(reg_out_link).* = out_link_stop;
    reg(reg_in_int_clr).* = int_clear_all;
    reg(reg_out_int_clr).* = int_clear_all;

    return .{
        .in_raw = in_raw,
        .out_raw = out_raw,
        .rx_done_desc = reg(reg_in_done_des).*,
        .tx_done_desc = reg(reg_out_done_des).*,
        .rx_eof_desc = reg(reg_in_suc_eof_des).*,
        .chunks = chunks,
        .elapsed_ticks = elapsed,
    };
}

/// 本章用不到的“更完整”的配置开关，留作对照阅读：
///   - `in_dscr_burst` / `out_dscr_burst`：描述符本身用 INCR 突发读，
///     描述符在 PSRAM 时有意义；
///   - `out_auto_wrback`：传输完把 length 回写到 TX 描述符；
///   - burst 模式 1/2/3 = incr4/incr8/incr16，PSRAM 上最大 128 字节。
pub fn enableDescriptorBurst() void {
    reg(reg_in_conf0).* |= in_dscr_burst;
    reg(reg_out_conf0).* |= out_dscr_burst;
}

pub fn enableAutoWriteBack() void {
    reg(reg_out_conf0).* |= out_auto_wrback;
}

pub fn setBurstMode(mode: u2) void {
    var in_v = reg(reg_in_conf0).*;
    in_v &= ~(@as(u32, 0x3) << in_burst_mode_shift);
    in_v |= @as(u32, mode) << in_burst_mode_shift;
    reg(reg_in_conf0).* = in_v;

    var out_v = reg(reg_out_conf0).*;
    out_v &= ~(@as(u32, 0x3) << out_burst_mode_shift);
    out_v |= @as(u32, mode) << out_burst_mode_shift;
    reg(reg_out_conf0).* = out_v;
}

/// 清掉 IN 的中断使能（本章从不打开，留接口显式说明“中断存在”）。
pub fn disableInterrupts() void {
    reg(reg_in_int_ena).* = 0;
}
