//! ch17-ethernet-mac-phy-driver：S31 千兆 EMAC 的寄存器级驱动。
//!
//! 层次刻意压平：没有 HAL、没有回调、没有 netif。**每一步都是一次寄存器写**，
//! 这样串口上打印的每一行都能对回 17.x 的表格。
//!
//! ## 初始化顺序（与 IDF 的 esp_eth 一致，只是去掉 RTOS）
//!
//!   1. 打开 EMAC 系统时钟（HP_SYS_CLKRST.EMAC_CTRL0.bit0）
//!      —— esp_eth_mac_esp.c:1186 `emac_ll_enable_bus_clock(0, true)`
//!   2. 同步复位 GMAC 寄存器（CNNT_SYS.HP_EMAC_CTRL.RST_EN 1→0）
//!      —— 同处 :1187 `emac_ll_reset_register(0)`
//!      *必须在* 任何 GMAC 寄存器访问之前完成。
//!   3. RGMII 时钟/接口选择（CNNT_SYS.GMAC_CTRL0 + RX/TX_CTRL + REF_CTRL）
//!      —— `emac_ll_clock_enable_rgmii()`（esp32s31/include/hal/emac_ll.h:1030）
//!   4. MDIO 分频（MAC.GMIIADDRESS.CS RCLK）—— `emac_hal_set_csr_clock_range`
//!   5. DMA 软复位（DMA.BUSMODE.SWR，等它自清零）
//!   6. MAC 默认配置（MACCR/MACFF）+ DMA 默认配置（BUSMODE/OPMODE）
//!   7. 描述符环地址 → DMA.TXDESCLIST / DMA.RXDESCLIST
//!   8. 启动 DMA（OPMODE.ST / SR），先收后发
//!
//! 与 IDF 的差别只有两处：**不开中断**（`DMA.INTRENABLE = 0`、MAC.INTMASK
//! 全屏蔽），以及**不配置 PLL**——RGMII 的 125 MHz TXC 由 CNNT 的 ref clock
//! 分频器产生，分频值来自“源 PLL 频率 / 125 MHz - 1”，源 PLL 是 bootloader
//! 留下的状态，**待真机验证**（见 17.6）。
//!
//! ## cache
//!
//! S31 的内部 SRAM 不经过 L1 D-cache（`soc_caps.h` 里没有
//! `SOC_CACHE_INTERNAL_MEM_VIA_L1CACHE`），所以本工程的描述符与缓冲放在
//! .bss 里**不需要**写回/无效操作，只需要 `fence rw, rw` 保证 MMIO 写序。
//! 同一份代码搬到 P4（有 L1 D-cache）则必须在交权前后加
//! `Cache_WriteBack_Addr` / `Cache_Invalidate_Addr`——见 17.7 的对照表。

const std = @import("std");

const descs = @import("descs.zig");
const hw = @import("hw.zig");
const phy = @import("phy.zig");
const regs = @import("regs.zig");

// ---------------------------------------------------------------------------
// 环与缓冲（全部在 .bss，_start 清零）
// ---------------------------------------------------------------------------

pub const tx_ring_len: usize = 2;
pub const rx_ring_len: usize = 4;
pub const rx_buf_size: usize = 1536;
pub const tx_buf_size: usize = 1518;

pub var tx_ring: [tx_ring_len]descs.TxDesc align(descs.desc_align) = undefined;
pub var rx_ring: [rx_ring_len]descs.RxDesc align(descs.desc_align) = undefined;
pub var tx_buf: [tx_buf_size]u8 align(16) = undefined;
pub var rx_bufs: [rx_ring_len][rx_buf_size]u8 align(16) = undefined;

/// 环游标：下一个待用的 TX / RX 描述符下标。
var tx_idx: usize = 0;
var rx_idx: usize = 0;

pub const Stats = struct {
    tx_started: u32 = 0,
    tx_done: u32 = 0,
    tx_err: u32 = 0,
    rx_frames: u32 = 0,
    rx_err: u32 = 0,
    rx_timeouts: u32 = 0,
};

pub var stats: Stats = .{};

/// 最近一次「收到但带错误位」的 RDES0。错误路径下描述符已经被重挂，
/// 所以现场必须在这里留一份，否则打印出来的是 0x80000000（新 OWN）。
pub var last_rx_err_des0: u32 = 0;

pub const Error = error{
    Timeout,
    MdioBusy,
    TxError,
    RxError,
    ShortFrame,
};

// ---------------------------------------------------------------------------
// 地址小工具
// ---------------------------------------------------------------------------

inline fn macReg(off: usize) usize {
    return regs.gmac + off;
}

inline fn dmaReg(off: usize) usize {
    return regs.gmac + off;
}

inline fn cnntReg(off: usize) usize {
    return regs.cnnt_sys + off;
}

inline fn addrOf(p: *const anyopaque) u32 {
    return @truncate(@intFromPtr(p));
}

// ---------------------------------------------------------------------------
// 1-3：时钟、复位、接口
// ---------------------------------------------------------------------------

/// 打开 EMAC 的系统时钟门控。
pub fn enableBusClock() void {
    hw.setBits(regs.hp_sys_clkrst + regs.clkrst_emac_ctrl0, regs.clkrst_emac_sys_clk_en);
}

/// 读回系统时钟门控位（打印用）。
pub fn busClockEnabled() bool {
    return (hw.readReg(regs.hp_sys_clkrst + regs.clkrst_emac_ctrl0) & regs.clkrst_emac_sys_clk_en) != 0;
}

/// GMAC 寄存器同步复位：RST_EN 置 1、保持、再清 0。
///
/// IDF 的 `emac_ll_reset_register` 是“写 1 立刻写 0”；这里多插几微秒，
/// 因为裸机没有 RCC 临界区保护，写序完全靠我们自己。
pub fn resetRegisters() void {
    const addr = cnntReg(regs.cnnt.hp_emac_ctrl);
    hw.setBits(addr, regs.cnnt_bits.rst_en);
    hw.fence();
    hw.delayUs(10);
    hw.clearBits(addr, regs.cnnt_bits.rst_en);
    hw.delayUs(10);
}

/// 复位后 MAC 版本寄存器应该变成默认值（低 8 位 = 0x37）；
/// 读它既能证明“复位真的生效”，也是打印里最有信息量的一行。
pub fn macVersion() u32 {
    return hw.readReg(macReg(regs.mac.version));
}

pub fn hwFeature() u32 {
    return hw.readReg(dmaReg(regs.dma.hw_feature));
}

/// RGMII 时钟与接口选择，逐位对应 `emac_ll_clock_enable_rgmii()`。
pub fn enableRgmiiClocks() void {
    const ctrl0 = cnntReg(regs.cnnt.gmac_ctrl0);
    const ref = cnntReg(regs.cnnt.hp_emac_ref_ctrl);
    const rmii_pad = cnntReg(regs.cnnt.hp_emac_rmii_pad_ctrl);
    const rmii = cnntReg(regs.cnnt.hp_emac_rmii_ctrl);
    const rx = cnntReg(regs.cnnt.hp_emac_rx_ctrl);
    const tx = cnntReg(regs.cnnt.hp_emac_tx_ctrl);

    // GMAC_CTRL0.PHY_INTF_SEL = 1（RGMII）
    hw.writeMasked(ctrl0, regs.cnnt_bits.phy_intf_sel_mask, regs.phy_intf_rgmii << regs.cnnt_bits.phy_intf_sel_shift);

    // RMII 的 pad 时钟关掉（RGMII 下 50M 输入不存在）
    hw.clearBits(rmii_pad, regs.cnnt_bits.rmii_pad_clk_en | regs.cnnt_bits.rmii_pad_clk_inv_en);
    hw.clearBits(rmii, regs.cnnt_bits.rmii_clk_sel | regs.cnnt_bits.rmii_clk_en);
    // TXC 由内部 ref clock 输出到 pad（GPIO13）
    hw.setBits(rmii, regs.cnnt_bits.rmii_pad_out_clk_en);

    // RX 用 RX pad 送来的时钟
    hw.setBits(rx, regs.cnnt_bits.rx_pad_clk_en | regs.cnnt_bits.rx_clk_sel);
    hw.clearBits(rx, regs.cnnt_bits.rx_pad_clk_inv_en);

    // TX 不用 pad 输入时钟；两个 180° 时钟必须打开，否则 EMAC 不启动
    hw.clearBits(tx, regs.cnnt_bits.tx_pad_clk_en | regs.cnnt_bits.tx_clk_sel);
    hw.setBits(tx, regs.cnnt_bits.tx_180_clk_en);
    hw.setBits(rx, regs.cnnt_bits.rx_180_clk_en);

    // 125 MHz TXC 的来源：ref clock = 源 PLL / (div+1)。
    // IDF 的算法是 div = src/125MHz - 1（esp_eth_mac_esp.c:255-270）。
    // 默认按 MPLL 500 MHz 算：500/125 = 4 → 写 3。**待真机验证**。
    hw.writeMasked(ref, 0x3 << regs.cnnt_bits.ref_clk_sel_shift, rgmii_ref_src_mpll << regs.cnnt_bits.ref_clk_sel_shift);
    hw.writeMasked(ref, 0xFF << regs.cnnt_bits.ref_clk_div_shift, rgmii_ref_div << regs.cnnt_bits.ref_clk_div_shift);
    hw.setBits(ref, regs.cnnt_bits.ref_clk_en);
}

/// ref clock 源：0 = MPLL，1 = CPLL，2 = APLL（emac_ll_ref_clock_select 的注释）。
pub const rgmii_ref_src_mpll: u32 = 0;
/// 分频寄存器值（= 源频率 / 125 MHz - 1）。MPLL 500 MHz → 3。
pub const rgmii_ref_div: u32 = 3;

/// 供打印：ref clock 的当前配置（sel、div、enable）。
pub const RefClock = struct { sel: u32, div: u32, enabled: bool };

pub fn readRefClock() RefClock {
    const v = hw.readReg(cnntReg(regs.cnnt.hp_emac_ref_ctrl));
    return .{
        .sel = (v >> regs.cnnt_bits.ref_clk_sel_shift) & 0x3,
        .div = (v >> regs.cnnt_bits.ref_clk_div_shift) & 0xFF,
        .enabled = (v & regs.cnnt_bits.ref_clk_en) != 0,
    };
}

// ---------------------------------------------------------------------------
// 4：MDIO
// ---------------------------------------------------------------------------

/// MDC 分频档位。默认用最保守档（/124），因为裸机拿不到确切的 SYS 频率。
pub var csr_div: u4 = regs.csr_div_safest;

pub fn setCsrDiv(div: u4) void {
    csr_div = div;
    hw.writeMasked(
        macReg(regs.mac.gmii_addr),
        regs.gmii_addr.csr_mask << regs.gmii_addr.csr_shift,
        @as(u32, div) << regs.gmii_addr.csr_shift,
    );
}

fn waitMdioIdle(timeout_us: u32) Error!void {
    const start = hw.nowUs();
    while ((hw.readReg(macReg(regs.mac.gmii_addr)) & regs.gmii_addr.busy) != 0) {
        if (hw.elapsedUs(start) > timeout_us) return Error.MdioBusy;
    }
}

/// 一次 MDIO 读（IEEE 802.3 第 22 条，硬件负责拼帧头/前导/TA）。
///
/// 超时用 1 MHz 的软件时钟，而不是空转计数：MDC 周期本身与 SYS 时钟相关，
/// 用固定循环次数会在不同主频下得到完全不同的实际超时。
pub fn mdioRead(phy_addr: u5, reg_addr: u5, timeout_us: u32) Error!u16 {
    try waitMdioIdle(timeout_us);
    // 先写“地址 + busy=0”，把 dev/reg 摆好（此时不会启动事务）。
    hw.writeReg(macReg(regs.mac.gmii_addr), regs.gmiiAddrValue(phy_addr, reg_addr, csr_div, false, false));
    hw.fence();
    // 再置 busy=1 启动；读操作时 MIIWRITE 保持 0。
    hw.writeReg(macReg(regs.mac.gmii_addr), regs.gmiiAddrValue(phy_addr, reg_addr, csr_div, false, true));
    try waitMdioIdle(timeout_us);
    return @truncate(hw.readReg(macReg(regs.mac.gmii_data)));
}

/// 一次 MDIO 写。数据必须在置 busy 之前写进 GMIIDATA。
pub fn mdioWrite(phy_addr: u5, reg_addr: u5, value: u16, timeout_us: u32) Error!void {
    try waitMdioIdle(timeout_us);
    hw.writeReg(macReg(regs.mac.gmii_addr), regs.gmiiAddrValue(phy_addr, reg_addr, csr_div, true, false));
    hw.writeReg(macReg(regs.mac.gmii_data), value);
    hw.fence();
    hw.writeReg(macReg(regs.mac.gmii_addr), regs.gmiiAddrValue(phy_addr, reg_addr, csr_div, true, true));
    try waitMdioIdle(timeout_us);
}

/// 扫 0..31 找第一个“ID 既不是 0 也不是 0xFFFFFFFF”的 PHY。
///
/// 全 0 = 没有任何器件应答（MDO/MDI 接反或 PHY 没供电）；
/// 全 F = 总线被拉高（MDIO 上拉，但没有器件驱动低电平）。
pub fn scanPhy(timeout_us: u32) ?u5 {
    var a: u32 = 0;
    while (a < 32) : (a += 1) {
        const addr: u5 = @intCast(a);
        const id1 = mdioRead(addr, phy.reg.phy_id1, timeout_us) catch 0;
        if (id1 != 0 and id1 != 0xFFFF) return addr;
    }
    return null;
}

pub const PhySnapshot = struct {
    addr: u5,
    ident: phy.Ident,
    bmsr: u16,
    anar: u16,
    anlpar: u16,
    gb_ctrl: u16,
    gb_status: u16,
};

pub fn readPhy(addr: u5, timeout_us: u32) Error!PhySnapshot {
    const id1 = try mdioRead(addr, phy.reg.phy_id1, timeout_us);
    const id2 = try mdioRead(addr, phy.reg.phy_id2, timeout_us);
    return .{
        .addr = addr,
        .ident = phy.decodeIdent(id1, id2),
        .bmsr = try mdioRead(addr, phy.reg.bmsr, timeout_us),
        .anar = try mdioRead(addr, phy.reg.anar, timeout_us),
        .anlpar = try mdioRead(addr, phy.reg.anlpar, timeout_us),
        .gb_ctrl = try mdioRead(addr, phy.reg.gb_t_ctrl, timeout_us),
        .gb_status = try mdioRead(addr, phy.reg.gb_t_status, timeout_us),
    };
}

/// 让 PHY 重新自协商：BMCR.AN_ENABLE | BMCR.RESTART_AUTONEG。
pub fn restartAutoneg(addr: u5, timeout_us: u32) Error!void {
    const v = try mdioRead(addr, phy.reg.bmcr, timeout_us);
    try mdioWrite(addr, phy.reg.bmcr, v | phy.bmcr.autoneg_enable | phy.bmcr.restart_autoneg, timeout_us);
}

// ---------------------------------------------------------------------------
// 6：MAC 默认配置
// ---------------------------------------------------------------------------

pub const Speed = enum { m10, m100, m1000 };

/// MACCR + MACFF 的默认值，逐条对应 `emac_hal_init_mac_default`。
///
/// 只改一处：`RT`（receive all）在诊断阶段置 1，让我们能收到任何帧
/// （包括 PHY 自己发的自协商/LLDP），便于“RX 环能进包”这条判据。
pub fn initMacConfig(speed: Speed, full_duplex: bool) u32 {
    var c: u32 = 0;
    c |= regs.config.prelen_7; // 前导 7 字节
    c |= regs.config.ifg_96; // 帧间间隔 96 bit
    c |= regs.config.bl_10;
    // APCS（pad/CRC strip）= 0，与 IDF 的 emac_ll_auto_pad_crc_strip_enable(false)
    // 一致：收到的帧**原样**交给软件，FCS 留在缓冲里，RDES0.FL 也把它算进去。
    // 置 1 时 MAC 只在长度字段 < 1536 时才剥 pad/FCS，行为更难解释。
    c &= ~regs.config.apcs;
    c |= regs.config.ipc; // 收到的帧做 IP 校验和检查（IDF 默认 ETH_CHECKSUM_HW）
    // DCRS（忽略 CRS）= 0：IDF 的 carrier_sense_enable(true) 就是清这一位。
    // 全双工下这一位本来无关紧要，但保持与 IDF 同值，减少“换芯片/换配置就变”
    // 的隐性差异。TWOKPE 同理保持 0（IDF 不置位）。
    c &= ~(regs.config.dcrs | regs.config.twokpe);
    // JABBER/WD 的语义是“置 1 = 关闭”，IDF 的 emac_ll_jabber_enable(true)
    // 写的是 jabber = !enable = 0，即保持定时器开启：这里照抄（位保持 0）。
    c &= ~(regs.config.jd | regs.config.wd);
    // TE/RE **不在这里**打开：IDF 的 init_mac_default 也不打开，它们在
    // emac_hal_start 里按 TE → ST → SR → RE 的顺序打开（见 startDma）。
    c &= ~(regs.config.tx | regs.config.rx);
    if (full_duplex) c |= regs.config.dm;
    switch (speed) {
        .m1000 => {
            c &= ~regs.config.ps; // PS = 0 → 1000M
            c &= ~regs.config.fes;
        },
        .m100 => {
            c |= regs.config.ps | regs.config.fes;
        },
        .m10 => {
            c |= regs.config.ps;
            c &= ~regs.config.fes;
        },
    }
    hw.writeReg(macReg(regs.mac.config), c);

    // 帧过滤：全通（诊断阶段）+ 接收所有广播/多播。
    var ff: u32 = 0;
    ff |= regs.frame_filter.promiscuous;
    ff |= regs.frame_filter.receive_all;
    ff |= regs.frame_filter.pass_all_multicast;
    // DBF 置 1 会丢广播，必须保持 0。
    hw.writeReg(macReg(regs.mac.frame_filter), ff);

    // MAC 中断全部屏蔽（INTMASK 是 1 = 屏蔽）。
    hw.writeReg(macReg(regs.mac.intr_mask), 0xFFFF_FFFF);
    return c;
}

pub fn readMacConfig() u32 {
    return hw.readReg(macReg(regs.mac.config));
}

pub fn readFrameFilter() u32 {
    return hw.readReg(macReg(regs.mac.frame_filter));
}

/// MAC 地址 0：低 32 位在前、高 16 位在后（与 emac_ll_set_addr 一致）。
pub fn setMacAddress(addr: [6]u8) void {
    hw.writeReg(macReg(regs.mac.addr0_high), (@as(u32, addr[5]) << 8) | addr[4]);
    hw.writeReg(macReg(regs.mac.addr0_low), (@as(u32, addr[3]) << 24) |
        (@as(u32, addr[2]) << 16) |
        (@as(u32, addr[1]) << 8) |
        addr[0]);
}

pub fn readMacAddress() [6]u8 {
    const lo = hw.readReg(macReg(regs.mac.addr0_low));
    const hi = hw.readReg(macReg(regs.mac.addr0_high));
    return .{
        @truncate(lo),
        @truncate(lo >> 8),
        @truncate(lo >> 16),
        @truncate(lo >> 24),
        @truncate(hi),
        @truncate(hi >> 8),
    };
}

// ---------------------------------------------------------------------------
// 5/6：DMA
// ---------------------------------------------------------------------------

/// DMA 软复位：SWR 置 1，然后等它自清零。超时返回错误而不是死等。
pub fn resetDma(timeout_us: u32) Error!void {
    hw.setBits(dmaReg(regs.dma.bus_mode), regs.bus_mode.sw_reset);
    const start = hw.nowUs();
    while ((hw.readReg(dmaReg(regs.dma.bus_mode)) & regs.bus_mode.sw_reset) != 0) {
        if (hw.elapsedUs(start) > timeout_us) return Error.Timeout;
    }
}

/// DMA 总线模式默认值（逐条对应 `emac_hal_init_dma_default`）。
pub fn initDmaDefaults() u32 {
    var v: u32 = 0;
    v |= @as(u32, regs.pbl_beats) << regs.bus_mode.pbl_shift;
    v |= regs.bus_mode.pr_1_1;
    v |= regs.bus_mode.addr_align;
    v |= regs.bus_mode.mixed_burst;
    v |= regs.bus_mode.alt_desc_size; // 增强描述符 32 字节
    // DSL = 0（链式、无跳字）
    v |= @as(u32, 0) << regs.bus_mode.dsl_shift;
    hw.writeReg(dmaReg(regs.dma.bus_mode), v);

    // 操作模式：轮询模型 → 先都关，启动时再置 ST/SR。
    var op: u32 = 0;
    op |= regs.op_mode.tx_thresh_64;
    op |= regs.op_mode.rx_thresh_64;
    op |= regs.op_mode.osf;
    // IDF：接收 store-forward 关（Rx FIFO 只有 256 B），发送也关。
    op &= ~(regs.op_mode.rx_store_forward | regs.op_mode.tx_store_forward);
    // 关掉“因为描述符不够就丢帧”的 flush（DFF = 0 → 允许 flush）。
    op &= ~regs.op_mode.dis_flush_rx;
    hw.writeReg(dmaReg(regs.dma.op_mode), op);

    // 中断全关（INTRENABLE = 0），纯轮询。
    hw.writeReg(dmaReg(regs.dma.intr_enable), 0);
    return v;
}

/// 把两个环的基址写进 DMA。
pub fn setRingAddresses() void {
    hw.writeReg(dmaReg(regs.dma.tx_desc_list), addrOf(&tx_ring[0]));
    hw.writeReg(dmaReg(regs.dma.rx_desc_list), addrOf(&rx_ring[0]));
}

/// 初始化 RX 环：每个描述符挂一个 1536 B 缓冲，链到下一个，最后一个是环尾。
/// 全部就绪后**统一**置 OWN，中间插一条 fence。
pub fn initRxRing(disable_intr: bool) void {
    var i: usize = 0;
    while (i < rx_ring_len) : (i += 1) {
        const next = descs.nextIndex(i, rx_ring_len);
        rx_ring[i] = .{
            .des0 = 0, // CPU 拥有
            .des1 = descs.rxDes1Init(rx_buf_size, disable_intr, i == rx_ring_len - 1),
            .buffer1 = addrOf(&rx_bufs[i][0]),
            .buffer2_or_next = addrOf(&rx_ring[next]),
            .ext_status = 0,
            .reserved = 0,
            .ts_low = 0,
            .ts_high = 0,
        };
    }
    hw.fence();
    i = 0;
    while (i < rx_ring_len) : (i += 1) {
        rx_ring[i].des0 = descs.rdes0.own;
    }
    hw.fence();
    rx_idx = 0;
}

/// 初始化 TX 环：描述符本身不动（等 txFrame 填），只把“下一个”指针串好。
pub fn initTxRing() void {
    var i: usize = 0;
    while (i < tx_ring_len) : (i += 1) {
        const next = descs.nextIndex(i, tx_ring_len);
        tx_ring[i] = .{
            .des0 = 0,
            .des1 = 0,
            .buffer1 = 0,
            .buffer2_or_next = addrOf(&tx_ring[next]),
            .reserved1 = 0,
            .reserved2 = 0,
            .ts_low = 0,
            .ts_high = 0,
        };
    }
    hw.fence();
    tx_idx = 0;
}

/// 启动：TE → ST → SR → RE，逐字照抄 IDF 的 `emac_hal_start`
/// （`emac_hal.c:638-655`）。
///
/// 那里的注释值得原样记住：
///   "the DMA could be started prior enabling the MAC transmitter. However,
///    it turned out that such order may cause the MAC transmitter hangs"
/// 即：**先开 MAC 发送器，再启动 DMA 发送**。反过来会挂住发送状态机。
/// 接收侧同理：先启动 DMA 接收，再开 MAC 接收器。
pub fn startDma() void {
    hw.setBits(macReg(regs.mac.config), regs.config.tx); // MAC TE
    hw.fence();
    hw.setBits(dmaReg(regs.dma.op_mode), regs.op_mode.start_tx); // DMA ST
    hw.fence();
    hw.setBits(dmaReg(regs.dma.op_mode), regs.op_mode.start_rx); // DMA SR
    hw.fence();
    hw.setBits(macReg(regs.mac.config), regs.config.rx); // MAC RE
    hw.fence();
}

/// 停机：顺序与 `emac_hal_stop` 一致（先停 DMA 发送，再停两个 MAC 状态机，
/// 最后停 DMA 接收）。
pub fn stopDma() void {
    hw.clearBits(dmaReg(regs.dma.op_mode), regs.op_mode.start_tx);
    hw.fence();
    hw.clearBits(macReg(regs.mac.config), regs.config.tx | regs.config.rx);
    hw.fence();
    hw.clearBits(dmaReg(regs.dma.op_mode), regs.op_mode.start_rx);
    hw.fence();
}

/// MAC 发送/接收状态机是否已使能（打印用）。
pub fn macTeRe() struct { te: bool, re: bool } {
    const cr = hw.readReg(macReg(regs.mac.config));
    return .{
        .te = (cr & regs.config.tx) != 0,
        .re = (cr & regs.config.rx) != 0,
    };
}

pub fn dmaStatus() u32 {
    return hw.readReg(dmaReg(regs.dma.status));
}

pub fn opMode() u32 {
    return hw.readReg(dmaReg(regs.dma.op_mode));
}

pub fn ringPointers() struct { tx: u32, rx: u32 } {
    return .{
        .tx = hw.readReg(dmaReg(regs.dma.cur_tx_desc)),
        .rx = hw.readReg(dmaReg(regs.dma.cur_rx_desc)),
    };
}

// ---------------------------------------------------------------------------
// 7：一发 / 一收
// ---------------------------------------------------------------------------

/// 发一帧（单缓冲、不分段）。返回 TDES0 的最终值供打印。
///
/// 交权顺序（17.7 的核心）：
///   a. 填 des1/buffer1（此刻 OWN 还是 0，DMA 不会碰它）；
///   b. `fence rw, rw` —— 保证缓冲内容与描述符字段先于 OWN 可见；
///   c. 写 des0（含 OWN = 1）—— 这一次写是“把描述符交给 DMA”的唯一动作；
///   d. 写 TXPOLLDEMAND 拍一下 DMA（环已经在跑时其实不必，但轮询模型下
///      它能把“DMA 停在 suspend”拉起来）。
pub fn txFrame(len: usize, timeout_us: u32) Error!u32 {
    if (len == 0 or len > tx_buf_size) return Error.ShortFrame;

    const i = tx_idx;
    stats.tx_started += 1;

    tx_ring[i].des1 = descs.txDes1(len);
    tx_ring[i].buffer1 = addrOf(&tx_buf[0]);
    hw.fence();

    const end_of_ring = (i == tx_ring_len - 1);
    tx_ring[i].des0 = descs.txDes0(end_of_ring);
    hw.fence();

    hw.writeReg(dmaReg(regs.dma.tx_poll_demand), 1);

    const start = hw.nowUs();
    while ((tx_ring[i].des0 & descs.tdes0.own) != 0) {
        if (hw.elapsedUs(start) > timeout_us) return Error.Timeout;
    }

    const des0 = tx_ring[i].des0;
    if (descs.txErrorMask(des0) != 0) {
        stats.tx_err += 1;
        return Error.TxError;
    }

    stats.tx_done += 1;
    tx_idx = descs.nextIndex(i, tx_ring_len);
    return des0;
}

pub const RxFrame = struct {
    desc_index: usize,
    len: usize,
    des0: u32,
    /// 帧的前 64 字节（够打印 14 字节以太网头 + 一点负载）。
    head: [64]u8,
};

/// 轮询 RX 环一次。
///
/// 返回 null 表示“这一轮没有新帧”（不是错误）；`Error.RxError` 表示
/// 收到了带错误位的帧（CRC/溢出/长度错），调用方打印后继续。
pub fn rxPoll(timeout_us: u32) Error!?RxFrame {
    const start = hw.nowUs();
    while (true) {
        const i = rx_idx;
        const des0 = rx_ring[i].des0;
        if ((des0 & descs.rdes0.own) == 0) {
            // DMA 已经交还描述符，字段有效。
            const err = descs.rxErrorMask(des0);
            const len = descs.rxFrameLength(des0);
            var out: RxFrame = .{
                .desc_index = i,
                .len = len,
                .des0 = des0,
                .head = @splat(0),
            };
            const n = @min(len, out.head.len);
            @memcpy(out.head[0..n], rx_bufs[i][0..n]);

            // 重新武装：先把 des0 清成 0（同时清掉全部状态位），fence 后置 OWN。
            rx_ring[i].des0 = 0;
            hw.fence();
            rx_ring[i].des0 = descs.rdes0.own;
            hw.fence();
            rx_idx = descs.nextIndex(i, rx_ring_len);

            if (err != 0) {
                last_rx_err_des0 = des0;
                stats.rx_err += 1;
                return Error.RxError;
            }
            stats.rx_frames += 1;
            return out;
        }
        if (hw.elapsedUs(start) > timeout_us) {
            stats.rx_timeouts += 1;
            return null;
        }
    }
}

/// 组装一个最小的以太网帧（用于 TX 自测）：
/// dst(6) + src(6) + ethertype(2) + payload(46..)。
pub fn buildTestFrame(dst: [6]u8, src: [6]u8, ethertype: u16, payload: []const u8) []const u8 {
    @memcpy(tx_buf[0..6], &dst);
    @memcpy(tx_buf[6..12], &src);
    tx_buf[12] = @truncate(ethertype >> 8);
    tx_buf[13] = @truncate(ethertype);
    const n = @min(payload.len, tx_buf_size - 14);
    @memcpy(tx_buf[14 .. 14 + n], payload[0..n]);
    var total = 14 + n;
    // 以太网最小帧 60 字节（不含 FCS）；不足由 MAC 自动 pad。
    if (total < 60) {
        while (total < 60) : (total += 1) tx_buf[total] = 0;
    }
    return tx_buf[0..total];
}

// ---------------------------------------------------------------------------

test "ring buffers are 32-byte aligned and static" {
    try std.testing.expect(@intFromPtr(&tx_ring[0]) % descs.desc_align == 0);
    try std.testing.expect(@intFromPtr(&rx_ring[0]) % descs.desc_align == 0);
}

test "buildTestFrame pads to the 60-byte minimum" {
    const dst = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const src = [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const frame = buildTestFrame(dst, src, 0x0806, "hi");
    try std.testing.expectEqual(@as(usize, 60), frame.len);
    try std.testing.expectEqual(@as(u8, 0x08), frame[12]);
    try std.testing.expectEqual(@as(u8, 0x06), frame[13]);
}
