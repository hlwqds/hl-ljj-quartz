//! ch17-ethernet-mac-phy-driver：S31 千兆 EMAC 的寄存器地图与字段编码。
//!
//! 本文件**不碰硬件**：只有常量与纯函数，因此可以被 `zig build test`
//! 在 x86_64 上直接测试（见 src/host_tests.zig）。所有读写在 src/emac.zig。
//!
//! ## 两个寄存器块，同一个基址
//!
//! S31 的 IP 是 Synopsys DWC_gmac（RGMII 千兆），寄存器被切成两块：
//!
//!   0x2035_0000 + 0x000..0x0FF   MAC（配置/过滤/MDIO/地址/中断）
//!   0x2035_0000 + 0x1000..0x105F DMA（总线模式/描述符环/状态/操作模式）
//!
//! 来源（ESP-IDF v6.1）：
//!   - `components/soc/esp32s31/register/soc/reg_base.h:16`
//!       DR_REG_GMAC_BASE = 0x20350000
//!   - `components/soc/esp32s31/register/soc/gmac_reg.h`
//!       :16   REG0  MACCONFIGURATION      + 0x0000
//!       :337  REG1  MACFRAMEFILTER        + 0x0004
//!       :533  REG4  GMIIADDRESS           + 0x0010
//!       :609  REG5  GMIIDATA              + 0x0014
//!       :623  REG6  FLOWCONTROL           + 0x0018
//!       :781  REG8  VERSION               + 0x0020
//!       :1161 REG14 INTERRUPTSTATUS       + 0x0038
//!       :1287 REG15 INTERRUPTMASK         + 0x003c
//!       :1349 REG16 MACADDRESS0HIGH       + 0x0040
//!       :1370 REG17 MACADDRESS0LOW        + 0x0044
//!       :3351 REG0  BUSMODE               + 0x1000（DMA 块）
//!       :3591 REG3  RECEIVEDESCRIPTORLIST + 0x100c
//!       :3606 REG4  TRANSMITDESCRIPTORLIST+ 0x1010
//!       :3622 REG5  STATUS                + 0x1014
//!       :3886 REG6  OPERATIONMODE         + 0x1018
//!       :4152 REG7  INTERRUPTENABLE       + 0x101c
//!       :4535 REG18 CURRENTHOSTTXDESC     + 0x1048
//!       :4547 REG19 CURRENTHOSTRXDESC     + 0x104c
//!       :4583 REG22 HWFEATURE             + 0x1058
//!
//! 同一个 IP 在 IDF 里还有两套符号：
//!   - `gmac_reg.h`：`GMAC_xxx` 位宏（CMSIS 风格，直接对地址做读改写）；
//!   - `emac_mac_struct.h` / `emac_dma_struct.h`：`emac_mac_dev_t` 位域结构体，
//!     HAL 用它（`emac_ll_set_*`，见
//!     `components/esp_hal_emac/esp32s31/include/hal/emac_ll.h`）。
//!
//! 本章用第一套（位宏）——裸机 Zig 里不需要位域结构体，用移位常量更直白；
//! 但两套的**位号必须一致**，所以每个常量下面都标了 struct 里的字段名，
//! 读代码时可以和 emac_ll.h 一一对上。

const std = @import("std");

// ---------------------------------------------------------------------------
// 基址
// ---------------------------------------------------------------------------

/// DR_REG_GMAC_BASE。MAC 块在 +0x000，DMA 块在 +0x1000。
pub const gmac: usize = 0x2035_0000;

/// DR_REG_CNNT_SYS_REG_BASE。GMAC 的时钟/复位/接口选择在 CNNT 域
/// （`cnnt_sys_reg.h`；注意该文件里的 `DR_REG_CNNT_BASE` 在 IDF 树里并没有
/// 定义，真正可用的基址是 reg_base.h:21 的 CNNT_SYS_REG_BASE —— 这一点在
/// 17.4 里会再解释一次）。
pub const cnnt_sys: usize = 0x2035_9000;

/// DR_REG_HP_SYS_CLKRST_BASE。EMAC 的系统时钟门控在 +0xC8 bit0。
pub const hp_sys_clkrst: usize = 0x2058_7000;

/// DR_REG_IO_MUX_BASE。每个 GPIO 一个 4 字节的 IO_MUX 配置寄存器。
pub const io_mux: usize = 0x2058_2000;

/// DR_REG_GPIO_BASE。GPIO 矩阵与输出使能。
pub const gpio: usize = 0x2058_3000;

// ---------------------------------------------------------------------------
// MAC 块偏移（gmac + off）
// ---------------------------------------------------------------------------

pub const mac = struct {
    pub const config = 0x000; // GMAC_REGISTER0_MACCONFIGURATIONREGISTER_REG
    pub const frame_filter = 0x004; // GMAC_REGISTER1_MACFRAMEFILTER_REG
    pub const hash_high = 0x008;
    pub const hash_low = 0x00c;
    pub const gmii_addr = 0x010; // GMAC_REGISTER4_GMIIADDRESSREGISTER_REG
    pub const gmii_data = 0x014; // GMAC_REGISTER5_GMIIDATAREGISTER_REG
    pub const flow_ctrl = 0x018;
    pub const vlan_tag = 0x01c;
    pub const version = 0x020; // 低 8 位 GMAC_SNPSVER
    pub const debug = 0x024;
    pub const intr_status = 0x038;
    pub const intr_mask = 0x03c;
    pub const addr0_high = 0x040;
    pub const addr0_low = 0x044;
    pub const addr1_high = 0x048;
};

// ---------------------------------------------------------------------------
// DMA 块偏移（gmac + off）
// ---------------------------------------------------------------------------

pub const dma = struct {
    pub const bus_mode = 0x1000;
    pub const tx_poll_demand = 0x1004;
    pub const rx_poll_demand = 0x1008;
    pub const rx_desc_list = 0x100c;
    pub const tx_desc_list = 0x1010;
    pub const status = 0x1014;
    pub const op_mode = 0x1018;
    pub const intr_enable = 0x101c;
    pub const missed_frames = 0x1020;
    pub const rx_intr_watchdog = 0x1024;
    pub const axi_bus_mode = 0x1028;
    pub const ahb_status = 0x102c;
    pub const cur_tx_desc = 0x1048;
    pub const cur_rx_desc = 0x104c;
    pub const cur_tx_buf = 0x1050;
    pub const cur_rx_buf = 0x1054;
    pub const hw_feature = 0x1058;
};

// ---------------------------------------------------------------------------
// CNNT_SYS 偏移（cnnt_sys + off）
//
// 来源：`components/soc/esp32s31/register/soc/cnnt_sys_reg.h`
//   :138  GMAC_MEM_LP_CTRL        + 0x1c
//   :338  HP_EMAC_CTRL            + 0x3c   EMAC_RST_EN bit1
//   :364  HP_EMAC_REF_CTRL        + 0x40
//   :397  HP_EMAC_RMII_PAD_CTRL   + 0x44
//   :416  HP_EMAC_RMII_CTRL       + 0x48
//   :449  HP_EMAC_RX_CTRL         + 0x4c
//   :482  HP_EMAC_TX_CTRL         + 0x50
//   :515  HP_EMAC_PTP_CTRL        + 0x54
//   :558  GMAC_CTRL0              + 0x60
// ---------------------------------------------------------------------------

pub const cnnt = struct {
    pub const gmac_mem_lp_ctrl = 0x01c;
    pub const hp_emac_ctrl = 0x03c;
    pub const hp_emac_ref_ctrl = 0x040;
    pub const hp_emac_rmii_pad_ctrl = 0x044;
    pub const hp_emac_rmii_ctrl = 0x048;
    pub const hp_emac_rx_ctrl = 0x04c;
    pub const hp_emac_tx_ctrl = 0x050;
    pub const hp_emac_ptp_ctrl = 0x054;
    pub const gmac_ctrl0 = 0x060;
};

/// HP_SYS_CLKRST + 0xC8：`HP_SYS_CLKRST_EMAC_CTRL0_REG`，bit0 = EMAC_SYS_CLK_EN。
/// 来源：`components/soc/esp32s31/register/soc/hp_sys_clkrst_reg.h:2194-2201`。
pub const clkrst_emac_ctrl0 = 0x0c8;
pub const clkrst_emac_sys_clk_en: u32 = 1 << 0;

// ---------------------------------------------------------------------------
// MAC 配置寄存器（+0x00）字段
//
// 位号与 `emac_mac_struct.h` 的 gmacconfig 位域一一对应（字段名写在注释里）。
// ---------------------------------------------------------------------------

pub const config = struct {
    pub const prelen_7: u32 = 0 << 0; // pltf
    pub const rx: u32 = 1 << 2; // rx
    pub const tx: u32 = 1 << 3; // tx
    pub const dc: u32 = 1 << 4; // deferralcheck
    pub const bl_10: u32 = 0 << 5; // backofflimit
    pub const apcs: u32 = 1 << 7; // padcrcstrip
    pub const dr: u32 = 1 << 9; // retry（置 1 = 只重试一次）
    pub const ipc: u32 = 1 << 10; // rxipcoffload
    pub const dm: u32 = 1 << 11; // duplex（1 = 全双工）
    pub const lm: u32 = 1 << 12; // loopback
    pub const ro: u32 = 1 << 13; // rxown
    pub const fes: u32 = 1 << 14; // fespeed（1 = 100M）
    pub const ps: u32 = 1 << 15; // mii（1 = 10/100，0 = 1000M）
    pub const dcrs: u32 = 1 << 16; // disablecrs
    pub const ifg_96: u32 = 0 << 17; // interframegap
    pub const je: u32 = 1 << 20; // jumboframe
    pub const jd: u32 = 1 << 22; // jabber（置 1 = 关 jabber 定时器）
    pub const wd: u32 = 1 << 23; // watchdog（置 1 = 关接收 watchdog）
    pub const twokpe: u32 = 1 << 27; // ass2kp
};

// ---------------------------------------------------------------------------
// MAC 帧过滤寄存器（+0x04）
// ---------------------------------------------------------------------------

pub const frame_filter = struct {
    pub const promiscuous: u32 = 1 << 0; // pmode：全通
    pub const hash_unicast: u32 = 1 << 1;
    pub const hash_multicast: u32 = 1 << 2;
    pub const da_inverse: u32 = 1 << 3;
    pub const pass_all_multicast: u32 = 1 << 4; // pam
    pub const block_broadcast: u32 = 1 << 5; // dbf（置 1 = 丢弃广播）
    pub const sa_inverse: u32 = 1 << 8;
    pub const sa_filter: u32 = 1 << 9;
    pub const receive_all: u32 = 1 << 31; // RA
};

// ---------------------------------------------------------------------------
// GMII 地址寄存器（+0x10）：MDIO 帧头由硬件拼，软件只填四个字段
//
// 位号来源：`emac_mac_struct.h` 的 emacgmiiaddr 位域
//   miibusy bit0、miiwrite bit1、miicsrclk[5:2]、miireg[10:6]、miidev[15:11]
// ---------------------------------------------------------------------------

pub const gmii_addr = struct {
    pub const busy: u32 = 1 << 0;
    pub const write: u32 = 1 << 1;
    pub const csr_shift: u5 = 2;
    pub const csr_mask: u32 = 0xF;
    pub const reg_shift: u5 = 6;
    pub const reg_mask: u32 = 0x1F;
    pub const dev_shift: u5 = 11;
    pub const dev_mask: u32 = 0x1F;
};

/// 组装 GMII 地址寄存器的值。
///
/// `csr_div` 是 MDC 分频档位（0..5），档位到除数的映射见 `csr_divisors`。
pub fn gmiiAddrValue(dev: u5, reg: u5, csr_div: u4, write_op: bool, start: bool) u32 {
    var v: u32 = 0;
    v |= @as(u32, csr_div) & gmii_addr.csr_mask;
    v |= (@as(u32, reg) & gmii_addr.reg_mask) << gmii_addr.reg_shift;
    v |= (@as(u32, dev) & gmii_addr.dev_mask) << gmii_addr.dev_shift;
    if (write_op) v |= gmii_addr.write;
    if (start) v |= gmii_addr.busy;
    return v;
}

/// MDC = CSR_CLK / divisor。表来自
/// `emac_hal.c:emac_crs_div_table = {42, 62, 16, 26, 102, 124}`。
pub const csr_divisors = [6]u32{ 42, 62, 16, 26, 102, 124 };

/// 在**不知道 SYS 频率**时选出最保守的档位：除数 ≥ 124 时，
/// 只要 SYS_CLK ≤ 310 MHz，MDC 就 ≤ 2.5 MHz（IEEE 802.3 第 22 条上限）。
pub const csr_div_safest: u4 = 5;

/// 给定 CSR（= MAC SYS）时钟频率，挑满足 MDC ≤ 2.5 MHz 的**最快**档位
/// （即合格档位里除数最小的那个）。与 IDF 的
/// `emac_hal_set_csr_clock_range` 同一个判据，但返回档位而不是写寄存器。
pub fn pickCsrDiv(sys_hz: u32) u4 {
    const mdc_max_hz: u32 = 2_500_000;
    var best_div: u32 = csr_divisors[csr_div_safest];
    var best: u4 = csr_div_safest;
    for (csr_divisors, 0..) |div, idx| {
        if (sys_hz / div <= mdc_max_hz and div < best_div) {
            best_div = div;
            best = @intCast(idx);
        }
    }
    return best;
}

// ---------------------------------------------------------------------------
// DMA 总线模式（+0x1000）
// 位号：gmac_reg.h GMAC_SWR bit0、DSL[6:2]、ATDS bit7、PBL[13:8]、
//        PR[15:14]、FB bit16、RPBL[22:17]、USP bit23、PBLX8 bit24、
//        AAL bit25、MB bit26、TXPR bit27、PRWG[30:28]、RIB bit31
// ---------------------------------------------------------------------------

pub const bus_mode = struct {
    pub const sw_reset: u32 = 1 << 0;
    pub const dsl_shift: u5 = 2;
    pub const alt_desc_size: u32 = 1 << 7; // ATDS：增强描述符（32 字节）
    pub const pbl_shift: u5 = 8;
    pub const pr_1_1: u32 = 0 << 14;
    pub const fixed_burst: u32 = 1 << 16;
    pub const usp: u32 = 1 << 23;
    pub const pblx8: u32 = 1 << 24;
    pub const addr_align: u32 = 1 << 25; // AAL
    pub const mixed_burst: u32 = 1 << 26; // MB
    pub const txpr: u32 = 1 << 27;
    pub const rib: u32 = 1 << 31;
};

/// 每条描述符的最大突发拍数。
///
/// **不能是 32**：`emac_ll.h` 的注释写着 "burst length 32 is intentionally NOT
/// defined here. Setting dma_burst_len to 32 causes overflow error on the AXI bus."
/// 这里取 16（`EMAC_LL_DMA_BURST_LENGTH_16BEAT`）。
pub const pbl_beats: u5 = 16;

// ---------------------------------------------------------------------------
// DMA 操作模式（+0x1018）
// 位号：gmac_reg.h GMAC_SR bit1、OSF bit2、RTC[4:3]、DGF bit5、FUF bit6、
//        FEF bit7、ST bit13、TTC[16:14]、FTF bit20、TSF bit21、DFF bit24、
//        RSF bit25、DT bit26
// ---------------------------------------------------------------------------

pub const op_mode = struct {
    pub const start_rx: u32 = 1 << 1; // SR
    pub const osf: u32 = 1 << 2; // 第二帧提前处理
    pub const rx_thresh_64: u32 = 0 << 3;
    pub const drop_giant: u32 = 1 << 5;
    pub const forward_undersize: u32 = 1 << 6;
    pub const forward_error: u32 = 1 << 7;
    pub const start_tx: u32 = 1 << 13; // ST
    pub const tx_thresh_64: u32 = 0 << 14;
    pub const flush_tx: u32 = 1 << 20; // FTF，自清零
    pub const tx_store_forward: u32 = 1 << 21; // TSF
    pub const dis_flush_rx: u32 = 1 << 24; // DFF
    pub const rx_store_forward: u32 = 1 << 25; // RSF
    pub const dis_drop_tcpip_err: u32 = 1 << 26; // DT
};

// ---------------------------------------------------------------------------
// DMA 状态（+0x1014）
// 位号：gmac_dma 状态寄存器 TI bit0、TPS bit1、TBU bit2、TJT bit3、OVF bit4、
//        UNF bit5、RI bit6、RU bit7、RPS bit8、RWT bit9、ETI bit10、FBI bit13、
//        ERI bit14、AIS bit15、NIS bit16、RPS/RWT…；RS[19:17]、TS[22:20]、
//        EB[25:23]
// ---------------------------------------------------------------------------

pub const dma_status = struct {
    pub const tx_int: u32 = 1 << 0;
    pub const tx_stopped: u32 = 1 << 1;
    pub const tx_buf_unavail: u32 = 1 << 2;
    pub const rx_overflow: u32 = 1 << 4;
    pub const tx_underflow: u32 = 1 << 5;
    pub const rx_int: u32 = 1 << 6;
    pub const rx_buf_unavail: u32 = 1 << 7;
    pub const rx_stopped: u32 = 1 << 8;
    pub const rx_watchdog: u32 = 1 << 9;
    pub const fatal_bus: u32 = 1 << 13;
    pub const abnormal_summary: u32 = 1 << 15;
    pub const normal_summary: u32 = 1 << 16;
    pub const rx_state_shift: u5 = 17;
    pub const tx_state_shift: u5 = 20;
    pub const bus_error_shift: u5 = 23;
};

// ---------------------------------------------------------------------------
// CNNT_SYS 字段
// ---------------------------------------------------------------------------

pub const cnnt_bits = struct {
    /// HP_EMAC_CTRL bit0：名称是 `EMAC_USELESS_CLK_EN`，IDF 从不置位。
    pub const useless_clk_en: u32 = 1 << 0;
    /// HP_EMAC_CTRL bit1：`EMAC_RST_EN`（同步复位，1 = 复位中）。
    pub const rst_en: u32 = 1 << 1;
    /// HP_EMAC_CTRL bit2：`EMAC_FORCE_NORST`。
    pub const force_norst: u32 = 1 << 2;

    /// HP_EMAC_REF_CTRL bit0-1：`EMAC_REF_CLK_SEL`（0 = MPLL 500M，1 = CPLL 300M）。
    pub const ref_clk_sel_shift: u5 = 0;
    /// HP_EMAC_REF_CTRL bit2：`EMAC_REF_CLK_EN`。
    pub const ref_clk_en: u32 = 1 << 2;
    /// HP_EMAC_REF_CTRL bit3：`EMAC_REF_50M_PAD_OUT_CLK_EN`（GPIO35 REF_GMAC_CLK）。
    pub const ref_50m_pad_out_clk_en: u32 = 1 << 3;
    /// HP_EMAC_REF_CTRL bit8-15：`EMAC_REF_CLK_DIV_NUM`。
    pub const ref_clk_div_shift: u5 = 8;

    /// HP_EMAC_RMII_PAD_CTRL bit1：`EMAC_RMII_PAD_CLK_EN`（外部 50M 输入使能）。
    pub const rmii_pad_clk_en: u32 = 1 << 1;
    /// HP_EMAC_RMII_PAD_CTRL bit2：`EMAC_RMII_PAD_CLK_INV_EN`。
    pub const rmii_pad_clk_inv_en: u32 = 1 << 2;

    /// HP_EMAC_RMII_CTRL bit0：`EMAC_RMII_CLK_SEL`（0 = 内部，1 = 外部）。
    pub const rmii_clk_sel: u32 = 1 << 0;
    /// HP_EMAC_RMII_CTRL bit1：`EMAC_RMII_CLK_EN`。
    pub const rmii_clk_en: u32 = 1 << 1;
    /// HP_EMAC_RMII_CTRL bit2：`EMAC_RMII_PAD_OUT_CLK_EN`（RGMII 的 TXC 输出）。
    pub const rmii_pad_out_clk_en: u32 = 1 << 2;
    /// HP_EMAC_RMII_CTRL bit8-12：`EMAC_RXTX_CLK_DIV_NUM`。
    pub const rxtx_clk_div_shift: u5 = 8;

    /// HP_EMAC_RX_CTRL：pad_clk_en bit0、pad_clk_inv_en bit1、clk_sel bit2、180_clk_en bit3
    pub const rx_pad_clk_en: u32 = 1 << 0;
    pub const rx_pad_clk_inv_en: u32 = 1 << 1;
    pub const rx_clk_sel: u32 = 1 << 2;
    pub const rx_180_clk_en: u32 = 1 << 3;

    /// HP_EMAC_TX_CTRL：同 RX_CTRL 的四个位
    pub const tx_pad_clk_en: u32 = 1 << 0;
    pub const tx_pad_clk_inv_en: u32 = 1 << 1;
    pub const tx_clk_sel: u32 = 1 << 2;
    pub const tx_180_clk_en: u32 = 1 << 3;

    /// GMAC_CTRL0 bit1：`SBD_FLOWCTRL`（MAC 控制帧回发）。
    pub const sbd_flowctrl: u32 = 1 << 1;
    /// GMAC_CTRL0 bit2-4：`PHY_INTF_SEL`（0 = MII，1 = RGMII，4 = RMII）。
    pub const phy_intf_sel_shift: u5 = 2;
    pub const phy_intf_sel_mask: u32 = 0x7 << 2;
    /// GMAC_CTRL0 bit5：`GMAC_MEM_CLK_FORCE_ON`（R/W）。GMAC 内部存储/AXI 时钟
    /// 默认门关；不给这一位，DMA 的 AXI 域可能没有时钟，SWR 就永远不自清。
    pub const mem_clk_force_on: u32 = 1 << 5;
    /// GMAC_CTRL0 bit6/7：`GMAC_RST_CLK_TX_N` / `GMAC_RST_CLK_RX_N`（RO）。
    /// 0 = 该时钟仍被复位拉住。
    pub const rst_clk_tx_n: u32 = 1 << 6;
    pub const rst_clk_rx_n: u32 = 1 << 7;
    /// GMAC_CTRL0 bit8：`GMAC_CACTIVE`（RO）。1 = GMAC-AXI 正在请求时钟。
    pub const gmac_cactive: u32 = 1 << 8;
};

/// `PHY_INTF_SEL` 的取值（emac_ll.h 的 `emac_ll_get_phy_intf` 反推）。
pub const phy_intf_mii: u32 = 0;
pub const phy_intf_rgmii: u32 = 1;
pub const phy_intf_rmii: u32 = 4;

// ---------------------------------------------------------------------------
// IO_MUX / GPIO 矩阵
//
// IO_MUX：每个 GPIO 一个寄存器，`io_mux + 4*gpio_num`。
//   位号（io_mux_reg.h）：FUN_PD bit7、FUN_PU bit8、FUN_IE bit9、
//   FUN_DRV[11:10]、MCU_SEL[14:12]。
// GPIO 矩阵（S31 是“信号索引 + 单跳”结构，见 gpio_struct.h）：
//   输出：`gpio + 0xaf4 + 4*io`，OUT_SEL[8:0]、OUT_INV_SEL bit9、
//         OEN_SEL bit10（1 = 用 GPIO_ENABLE_REG 作为输出使能）、OEN_INV_SEL bit11；
//   输入：`gpio + 0x2f4 + 4*signal`，IN_SEL[7:0]（GPIO 号）、IN_INV_SEL bit8、
//         SIG_IN_SEL bit9（1 = 走矩阵，0 = 旁路直连 IO_MUX）。
// ---------------------------------------------------------------------------

pub const iomux = struct {
    pub const fun_pd: u32 = 1 << 7;
    pub const fun_pu: u32 = 1 << 8;
    pub const fun_ie: u32 = 1 << 9;
    pub const drv_shift: u5 = 10;
    pub const mcu_sel_shift: u5 = 12;
    pub const mcu_sel_mask: u32 = 0x7 << 12;
    /// MCU_SEL = 1 表示“该脚由 GPIO 矩阵/软件控制”，0 是各外设的 IO_MUX 功能。
    pub const mcu_sel_gpio: u32 = 1 << 12;
};

pub const gpio_matrix = struct {
    pub const out_sel_base = 0xaf4;
    pub const in_sel_base = 0x2f4;
    pub const out_sel_mask: u32 = 0x1FF;
    pub const out_inv_sel: u32 = 1 << 9;
    pub const oen_sel: u32 = 1 << 10;
    pub const oen_inv_sel: u32 = 1 << 11;
    pub const in_sel_mask: u32 = 0xFF;
    pub const in_inv_sel: u32 = 1 << 8;
    pub const sig_in_sel: u32 = 1 << 9;
    pub const enable_w1ts = 0x038;
    pub const enable_w1tc = 0x03c;
};

/// IO_MUX 配置寄存器地址。
pub fn iomuxAddr(gpio_num: u5) usize {
    return io_mux + 4 * @as(usize, gpio_num);
}

/// GPIO 输出信号选择寄存器地址（按 **GPIO 号**索引）。
pub fn gpioOutSelAddr(gpio_num: u5) usize {
    return gpio + gpio_matrix.out_sel_base + 4 * @as(usize, gpio_num);
}

/// GPIO 输入信号选择寄存器地址（按 **信号号**索引，S31 的单跳矩阵）。
pub fn gpioInSelAddr(signal_idx: u8) usize {
    return gpio + gpio_matrix.in_sel_base + 4 * @as(usize, signal_idx);
}

// ---------------------------------------------------------------------------
// 信号号（gpio_sig_map.h）
// ---------------------------------------------------------------------------

/// MDIO 数据输入（PHY → MAC）。
pub const sig_gmii_mdi_in: u8 = 107;
/// MDC 时钟输出。
pub const sig_gmii_mdc_out: u8 = 108;
/// MDIO 数据输出（MAC → PHY）。
pub const sig_gmii_mdo_out: u8 = 109;
/// RGMII TX_CTL（= MII TXEN）。
pub const sig_gmac_txen_out: u8 = 178;
/// RGMII RX_CTL（= MII RXDV）。
pub const sig_gmac_rxdv_in: u8 = 178;
/// RXD0（输入 179）。
pub const sig_gmac_rxd0_in: u8 = 179;
/// TXD0（输出 179）。
pub const sig_gmac_txd0_out: u8 = 179;
/// RX 时钟输入。
pub const sig_gmac_rx_clk_in: u8 = 184;
/// TX 时钟输入（MII 用；RGMII 下 TXC 由 pad 输出，不接这个信号）。
pub const sig_gmac_tx_clk_in: u8 = 185;

// ---------------------------------------------------------------------------
// IO_MUX 功能号（io_mux_reg.h，GMAC 全部是 2）
// ---------------------------------------------------------------------------

pub const func_gmac: u32 = 2;

// ---------------------------------------------------------------------------

comptime {
    // 位域常量自检：写错一个位在主机侧就会炸，不用等上板。
    if (gmiiAddrValue(0, 0, 0, false, false) != 0) @compileError("gmii addr 0 值必须为 0");
    if (gmiiAddrValue(0, 0, 0, true, false) != 1 << 1) @compileError("write 位");
    if (gmiiAddrValue(0, 0, 0, false, true) != 1 << 0) @compileError("busy 位");
    if (gmiiAddrValue(0, 1, 0, false, false) != 1 << 6) @compileError("reg 移位");
    if (gmiiAddrValue(1, 0, 0, false, false) != 1 << 11) @compileError("dev 移位");
}

test "csr divider stays under 2.5 MHz at any plausible SYS clock" {
    var sys: u32 = 40_000_000;
    while (sys <= 300_000_000) : (sys += 20_000_000) {
        const div = csr_divisors[csr_div_safest];
        try std.testing.expect(sys / div <= 2_500_000);
    }
}

test "pickCsrDiv picks fastest legal divider" {
    // SYS 240 MHz：/42 = 5.7 MHz、/62 = 3.9 MHz 都超上限；/102 = 2.35 MHz 合法
    // 且是合格档里最快的（/124 更慢）。档位 4 对应除数 102。
    try std.testing.expectEqual(@as(u4, 4), pickCsrDiv(240_000_000));
    // SYS 80 MHz：/42 = 1.9 MHz 合法且最快（/16 与 /26 超上限）。档位 0。
    try std.testing.expectEqual(@as(u4, 0), pickCsrDiv(80_000_000));
}
