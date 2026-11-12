//! ch17-ethernet-mac-phy-driver：DMA 描述符环（增强描述符，32 字节 = 8 字）。
//!
//! 本文件是**纯数据结构 + 纯函数**：主机侧 `zig build test` 会检查
//! 字段偏移、`OWN` 位与环索引回绕。真正的收发在 src/emac.zig。
//!
//! ## 为什么是 32 字节
//!
//! S31 的 DWC_gmac 支持两种描述符格式：
//!
//!   - 普通描述符：4 字（16 字节）；
//!   - 增强描述符：8 字（32 字节），带时间戳、扩展状态、校验和卸载字段。
//!
//! IDF 统一用增强格式：`emac_hal_init_dma_default` 里
//! `emac_ll_enhance_desc_enable(hal->dma_regs, true)`（= BUSMODE.ATDS bit7），
//! 描述符类型 `eth_dma_tx_descriptor_t` / `eth_dma_rx_descriptor_t` 各 32 字节。
//!
//! 来源：`components/esp_hal_emac/include/hal/emac_hal.h`
//!   :33   EMAC_HAL_DMA_DESC_SIZE = 32（非 P4；:31 是 P4 的 64）
//!   :56-109  eth_dma_tx_descriptor_t（TDES0 在 :58、OWN 在 :85）
//!   :116-187 eth_dma_rx_descriptor_t（RDES0 在 :118、OWN 在 :137）
//!   :37-47   TDES0 的控制位宏（INTR_ON_COMPLET bit30、VLAN 位 [19:18] …）
//!
//! ## OWN 位是唯一的同步点
//!
//! `OWN = 1` 表示“描述符归 DMA”，`OWN = 0` 表示“归 CPU”。CPU 写描述符后
//! 必须 `fence rw, rw` 再置 OWN；DMA 回写后 CPU 读到的 OWN = 0 之前，
//! 描述符里的其它字段都不可信。这是本章 17.7 的全部内容。

const std = @import("std");

/// 增强描述符固定 32 字节（8 个字）。
pub const desc_bytes: usize = 32;

/// 硬件要求的最小对齐：`EMAC_LL_DMA_MEM_ALIGNMENT = 8`（emac_ll.h:95）。
/// 实际用 32 字节对齐，顺带满足 cache line 的最小粒度。
pub const desc_align: usize = 32;

// ---------------------------------------------------------------------------
// TX 描述符
// ---------------------------------------------------------------------------

pub const TxDesc = extern struct {
    des0: u32,
    des1: u32,
    buffer1: u32,
    buffer2_or_next: u32,
    reserved1: u32,
    reserved2: u32,
    ts_low: u32,
    ts_high: u32,
};

comptime {
    if (@sizeOf(TxDesc) != desc_bytes) @compileError("TX 描述符必须是 32 字节");
    if (@offsetOf(TxDesc, "buffer1") != 8) @compileError("Buffer1Addr 在偏移 8");
    if (@offsetOf(TxDesc, "buffer2_or_next") != 12) @compileError("Next 在偏移 12");
}

/// TDES0 位（来源 emac_hal.h:37-47 的控制位宏 + :58-85 的结构体位域）。
pub const tdes0 = struct {
    pub const deferred: u32 = 1 << 0;
    pub const underflow_err: u32 = 1 << 1;
    pub const excessive_deferral: u32 = 1 << 2;
    pub const excessive_collision: u32 = 1 << 8;
    pub const late_collision: u32 = 1 << 9;
    pub const no_carrier: u32 = 1 << 10;
    pub const loss_carrier: u32 = 1 << 11;
    pub const frame_flushed: u32 = 1 << 13;
    pub const jabber_timeout: u32 = 1 << 14;
    pub const err_summary: u32 = 1 << 15;
    pub const ip_head_err: u32 = 1 << 16;
    pub const second_addr_chained: u32 = 1 << 20;
    pub const end_of_ring: u32 = 1 << 21;
    pub const checksum_shift: u5 = 22;
    pub const crc_replace: u32 = 1 << 24;
    pub const ts_enable: u32 = 1 << 25;
    pub const disable_pad: u32 = 1 << 26;
    pub const disable_crc: u32 = 1 << 27;
    pub const first_segment: u32 = 1 << 28;
    pub const last_segment: u32 = 1 << 29;
    pub const intr_on_complete: u32 = 1 << 30;
    pub const own: u32 = 1 << 31;
};

/// TDES1：Buffer1Size[12:0]、Buffer2Size[28:16]、SAInsertControl[31:29]。
pub const tdes1 = struct {
    pub const size1_shift: u5 = 0;
    pub const size1_mask: u32 = 0x1FFF;
    pub const size2_shift: u5 = 16;
    pub const size2_mask: u32 = 0x1FFF;
};

/// 我们这个驱动用的最小 TDES0：单缓冲 + 首尾同段 + 链式 + 完成即中断。
/// `end_of_ring` 只在环的最后一个描述符上置位（TER）。
pub fn txDes0(end_of_ring: bool) u32 {
    var v: u32 = tdes0.own |
        tdes0.first_segment |
        tdes0.last_segment |
        tdes0.second_addr_chained |
        tdes0.intr_on_complete;
    if (end_of_ring) v |= tdes0.end_of_ring;
    return v;
}

/// 环尾描述符用的 TDES0（`txDes0(true)` 的别名，供主程序打印对照）。
pub fn txDes0Owned() u32 {
    return txDes0(true);
}

/// `len` 必须 ≤ 1518（我们只发单帧，不分段）。
pub fn txDes1(len: usize) u32 {
    const n: u32 = @intCast(len & tdes1.size1_mask);
    return n << tdes1.size1_shift;
}

/// 打印用：把 TDES0 里的错误位折叠成一个位掩码（0 = 没有错误）。
pub fn txErrorMask(des0: u32) u32 {
    return des0 & (tdes0.underflow_err |
        tdes0.excessive_collision |
        tdes0.late_collision |
        tdes0.no_carrier |
        tdes0.loss_carrier |
        tdes0.frame_flushed |
        tdes0.jabber_timeout |
        tdes0.err_summary);
}

// ---------------------------------------------------------------------------
// RX 描述符
// ---------------------------------------------------------------------------

pub const RxDesc = extern struct {
    des0: u32,
    des1: u32,
    buffer1: u32,
    buffer2_or_next: u32,
    ext_status: u32,
    reserved: u32,
    ts_low: u32,
    ts_high: u32,
};

comptime {
    if (@sizeOf(RxDesc) != desc_bytes) @compileError("RX 描述符必须是 32 字节");
    if (@offsetOf(RxDesc, "ext_status") != 16) @compileError("扩展状态在偏移 16");
}

/// RDES0 位（来源 emac_hal.h:118-137 的结构体位域）。
pub const rdes0 = struct {
    pub const ext_status_available: u32 = 1 << 0;
    pub const crc_err: u32 = 1 << 1;
    pub const dribble_err: u32 = 1 << 2;
    pub const receive_err: u32 = 1 << 3;
    pub const rx_watchdog: u32 = 1 << 4;
    pub const frame_type: u32 = 1 << 5;
    pub const late_collision: u32 = 1 << 6;
    pub const ts_or_ip_err: u32 = 1 << 7;
    pub const last_descriptor: u32 = 1 << 8;
    pub const first_descriptor: u32 = 1 << 9;
    pub const vlan_tag: u32 = 1 << 10;
    pub const overflow_err: u32 = 1 << 11;
    pub const length_err: u32 = 1 << 12;
    pub const sa_filter_fail: u32 = 1 << 13;
    pub const descriptor_err: u32 = 1 << 14;
    pub const err_summary: u32 = 1 << 15;
    pub const frame_length_shift: u5 = 16;
    pub const frame_length_mask: u32 = 0x3FFF;
    pub const da_filter_fail: u32 = 1 << 30;
    pub const own: u32 = 1 << 31;
};

/// RDES1：Buffer1Size[12:0]、SecondAddressChained bit14、RingEnd bit15、
/// Buffer2Size[28:16]、DisableInterruptOnComplete bit31。
pub const rdes1 = struct {
    pub const size1_shift: u5 = 0;
    pub const size1_mask: u32 = 0x1FFF;
    pub const chained: u32 = 1 << 14;
    pub const end_of_ring: u32 = 1 << 15;
    pub const size2_shift: u5 = 16;
    pub const disable_intr_on_complete: u32 = 1 << 31;
};

/// CPU 初始化一个空 RX 描述符：把 buffer 尺寸写进 RDES1。
///
/// `disable_intr = true` 时置 RDES1[31]（DIC），DMA 收完这一帧不置 RI 位——
/// 本章是轮询模型（17.8），中断只作为可选路径。
///
/// `end_of_ring` **只能在环的最后一个描述符上置位**（RER）：如果每个描述符都
/// 置 RER，DMA 会把每一个都当成环尾，环就退化成“只用一个描述符”。
pub fn rxDes1Init(buf_size: usize, disable_intr: bool, end_of_ring: bool) u32 {
    const n: u32 = @intCast(buf_size & rdes1.size1_mask);
    var v: u32 = n << rdes1.size1_shift;
    v |= rdes1.chained;
    if (end_of_ring) v |= rdes1.end_of_ring;
    if (disable_intr) v |= rdes1.disable_intr_on_complete;
    return v;
}

/// 从 RDES0 取帧长（不含 FCS 的字节数，由 MAC 剥离）。
pub fn rxFrameLength(des0: u32) usize {
    return @intCast((des0 >> rdes0.frame_length_shift) & rdes0.frame_length_mask);
}

/// 打印用：把接收错误位折叠成一个位掩码。
pub fn rxErrorMask(des0: u32) u32 {
    return des0 & (rdes0.crc_err |
        rdes0.dribble_err |
        rdes0.receive_err |
        rdes0.rx_watchdog |
        rdes0.late_collision |
        rdes0.overflow_err |
        rdes0.length_err |
        rdes0.descriptor_err |
        rdes0.err_summary);
}

// ---------------------------------------------------------------------------
// 环
// ---------------------------------------------------------------------------

/// `i` 的下一个索引（回绕）。环长度必须是 2 的幂时也能用取模版本；
/// 这里直接用 `%`，因为 n 只有 2/4/8，速度无关紧要。
pub fn nextIndex(i: usize, n: usize) usize {
    return (i + 1) % n;
}

test "descriptor layout matches the 32-byte enhanced format" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(TxDesc));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RxDesc));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(TxDesc, "buffer1"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(RxDesc, "ext_status"));
}

test "own bit is the top bit of both descriptors" {
    try std.testing.expectEqual(@as(u32, 0x8000_0000), tdes0.own);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), rdes0.own);
}

test "tx des1 encodes length in the low 13 bits" {
    try std.testing.expectEqual(@as(u32, 60), txDes1(60));
    try std.testing.expectEqual(@as(u32, 0x1FFF), txDes1(0x1FFF));
    const d0 = txDes0Owned();
    try std.testing.expectEqual(@as(u32, 1), (d0 & tdes0.own) >> 31);
    try std.testing.expect((d0 & tdes0.first_segment) != 0);
    try std.testing.expect((d0 & tdes0.last_segment) != 0);
}

test "rx des1 encodes buffer size and ring flags" {
    const middle = rxDes1Init(1536, true, false);
    try std.testing.expectEqual(@as(u32, 1536), middle & rdes1.size1_mask);
    try std.testing.expect((middle & rdes1.chained) != 0);
    try std.testing.expect((middle & rdes1.end_of_ring) == 0);
    try std.testing.expect((middle & rdes1.disable_intr_on_complete) != 0);

    const last = rxDes1Init(1536, false, true);
    try std.testing.expect((last & rdes1.end_of_ring) != 0);
    try std.testing.expect((last & rdes1.disable_intr_on_complete) == 0);
}

test "rx frame length extraction" {
    // 帧长 64 放在 [29:16]。
    const des0 = (@as(u32, 64) << rdes0.frame_length_shift) | rdes0.first_descriptor | rdes0.last_descriptor;
    try std.testing.expectEqual(@as(usize, 64), rxFrameLength(des0));
    try std.testing.expectEqual(@as(u32, 0), rxErrorMask(des0));
}

test "ring index wraps" {
    try std.testing.expectEqual(@as(usize, 0), nextIndex(3, 4));
    try std.testing.expectEqual(@as(usize, 1), nextIndex(0, 4));
}
