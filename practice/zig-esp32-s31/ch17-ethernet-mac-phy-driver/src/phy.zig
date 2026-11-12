//! ch17-ethernet-mac-phy-driver：PHY 标准寄存器（IEEE 802.3 第 22 条）的
//! 解码。纯函数，主机侧可测。
//!
//! MDIO 只是“读一个 16 位寄存器”的通道（17.5）；真正有语义的是 PHY 的
//! 寄存器内容，而它们全部由 IEEE 802.3 规定，与具体厂商无关：
//!
//!   0x00 BMCR    基本模式控制（复位、自协商使能、速率/双工强制）
//!   0x01 BMSR    基本模式状态（链路、自协商能力/完成、支持的速率）
//!   0x02 PHYID1  OUI 高 16 位中的 [21:6]
//!   0x03 PHYID2  OUI[5:0] + 型号 + 版本
//!   0x04 ANAR    自协商通告（我们告诉对端支持什么）
//!   0x05 ANLPAR  链路伙伴通告（对端说它支持什么）
//!   0x09 1000BASE-T 控制（千兆双工/主从偏好）
//!   0x0A 1000BASE-T 状态（千兆链路、主从、本地/远端接收状态）
//!
//! 「打印 vendor/model」的做法：读 0x02/0x03 拼出 OUI，再查本文件里的小表。
//! 表只收录几家常见 PHY，其余按 OUI 原样打印——比猜一个名字诚实。

const std = @import("std");

pub const reg = struct {
    pub const bmcr: u5 = 0x00;
    pub const bmsr: u5 = 0x01;
    pub const phy_id1: u5 = 0x02;
    pub const phy_id2: u5 = 0x03;
    pub const anar: u5 = 0x04;
    pub const anlpar: u5 = 0x05;
    pub const aner: u5 = 0x06;
    pub const gb_t_ctrl: u5 = 0x09;
    pub const gb_t_status: u5 = 0x0A;
};

pub const bmcr = struct {
    pub const reset: u16 = 1 << 15;
    pub const loopback: u16 = 1 << 14;
    pub const speed_lsb: u16 = 1 << 13;
    pub const autoneg_enable: u16 = 1 << 12;
    pub const power_down: u16 = 1 << 11;
    pub const isolate: u16 = 1 << 10;
    pub const restart_autoneg: u16 = 1 << 9;
    pub const duplex_full: u16 = 1 << 8;
    pub const speed_msb: u16 = 1 << 6;
};

pub const bmsr = struct {
    pub const extended_status: u16 = 1 << 8;
    pub const an_complete: u16 = 1 << 5;
    pub const an_ability: u16 = 1 << 3;
    pub const link_up: u16 = 1 << 2;
    /// [15:9] 的能力位：100BASE-T4 / 100BASE-TX FD / 100BASE-TX HD / 10BASE-T FD / 10BASE-T HD。
    pub const cap_100_t4: u16 = 1 << 9;
    pub const cap_100_tx_fd: u16 = 1 << 10;
    pub const cap_100_tx_hd: u16 = 1 << 11;
    pub const cap_10_t_fd: u16 = 1 << 12;
    pub const cap_10_t_hd: u16 = 1 << 13;
};

pub const anar_bits = struct {
    pub const selector_mask: u16 = 0x1F;
    pub const selector_8023: u16 = 0x01;
    pub const tech_10_hd: u16 = 1 << 5;
    pub const tech_10_fd: u16 = 1 << 6;
    pub const tech_100_hd: u16 = 1 << 7;
    pub const tech_100_fd: u16 = 1 << 8;
    pub const remote_fault: u16 = 1 << 12;
    pub const pause_asym: u16 = 1 << 13;
    pub const pause: u16 = 1 << 14;
    pub const next_page: u16 = 1 << 15;
};

pub const gb_t_ctrl_bits = struct {
    pub const adv_1000_fd: u16 = 1 << 9;
    pub const adv_1000_hd: u16 = 1 << 10;
    pub const master_slave_shift: u4 = 11;
};

pub const gb_t_status_bits = struct {
    pub const lp_1000_fd: u16 = 1 << 11;
    pub const lp_1000_hd: u16 = 1 << 12;
    pub const local_rx_ok: u16 = 1 << 13;
    pub const master: u16 = 1 << 14;
    pub const ms_config_fault: u16 = 1 << 15;
};

/// 从 PHYID1/PHYID2 拆出的标识。`raw` 保留 32 位原值，便于对照数据手册。
pub const Ident = struct {
    oui: u32,
    model: u16,
    revision: u16,
    raw: u32,

    pub fn vendor(self: Ident) []const u8 {
        for (oui_table) |entry| {
            if (entry.oui == self.oui) return entry.name;
        }
        return "unknown";
    }
};

/// PHYID1 = OUI[21:6]，PHYID2 = OUI[5:0] << 10 | MODEL[5:0] << 4 | REV[3:0]。
pub fn decodeIdent(id1: u16, id2: u16) Ident {
    const oui: u32 = (@as(u32, id1) << 6) | (@as(u32, id2) >> 10);
    const model: u16 = (id2 >> 4) & 0x3F;
    const revision: u16 = id2 & 0xF;
    return .{
        .oui = oui,
        .model = model,
        .revision = revision,
        .raw = (@as(u32, id1) << 16) | id2,
    };
}

const OuiEntry = struct { oui: u32, name: []const u8 };

/// 解码后的 OUI 表（只收几家常见以太网 PHY 厂商）。
///
/// 注意：这里的 OUI 是**按 802.3 规则从 ID 寄存器拼出来**的 22 位值，
/// 不是数据手册封面上的 24 位公司 OUI。举例：
///   RTL8211 的 ID = 0x001CC916 → OUI = (0x001C<<6)|(0xC916>>10) = 0x000732
///   Marvell 88E1512 = 0x01410DD1 → 0x005043
///   TI DP83867     = 0x2000A231 → 0x0080028
const oui_table = [_]OuiEntry{
    .{ .oui = 0x0007_32, .name = "Realtek" },
    .{ .oui = 0x0050_43, .name = "Marvell" },
    .{ .oui = 0x0800_28, .name = "Texas Instruments" },
};

/// 自协商结果的极简描述：只覆盖我们关心的四档（10/100/1000 × 半/全）。
pub const LinkMode = enum {
    unknown,
    m10_hd,
    m10_fd,
    m100_hd,
    m100_fd,
    m1000_fd,
};

pub fn modeName(mode: LinkMode) []const u8 {
    return switch (mode) {
        .unknown => "unknown",
        .m10_hd => "10M half",
        .m10_fd => "10M full",
        .m100_hd => "100M half",
        .m100_fd => "100M full",
        .m1000_fd => "1000M full",
    };
}

/// 由 ANAR/ANLPAR 的“交集”判断协商结果（10/100）。
///
/// 千兆不走这 16 位（1000BASE-T 另在寄存器 9/10），所以返回 m1000_fd
/// 需要调用方先看 `gb_t_status`。
pub fn negotiatedFromPar(local: u16, remote: u16) LinkMode {
    const both = local & remote;
    if ((both & anar_bits.tech_100_fd) != 0) return .m100_fd;
    if ((both & anar_bits.tech_100_hd) != 0) return .m100_hd;
    if ((both & anar_bits.tech_10_fd) != 0) return .m10_fd;
    if ((both & anar_bits.tech_10_hd) != 0) return .m10_hd;
    return .unknown;
}

/// 千兆协商结果：GB_T 状态寄存器 bit11（对端 1000FD）+ bit13（本地接收 OK）。
pub fn negotiated1000(status: u16) LinkMode {
    if ((status & gb_t_status_bits.lp_1000_fd) != 0 and
        (status & gb_t_status_bits.local_rx_ok) != 0)
    {
        return .m1000_fd;
    }
    return .unknown;
}

/// 把 BMSR 的能力位摘成一个紧凑字符串，供一行打印。
pub fn bmsrCaps(buf: []u8, status: u16) []const u8 {
    const caps = [_]struct { bit: u16, name: []const u8 }{
        .{ .bit = bmsr.cap_100_t4, .name = "100T4" },
        .{ .bit = bmsr.cap_100_tx_fd, .name = "100TX-FD" },
        .{ .bit = bmsr.cap_100_tx_hd, .name = "100TX-HD" },
        .{ .bit = bmsr.cap_10_t_fd, .name = "10T-FD" },
        .{ .bit = bmsr.cap_10_t_hd, .name = "10T-HD" },
    };
    var n: usize = 0;
    for (caps) |c| {
        if ((status & c.bit) == 0) continue;
        if (n != 0) {
            if (n >= buf.len) break;
            buf[n] = ',';
            n += 1;
        }
        for (c.name) |ch| {
            if (n >= buf.len) break;
            buf[n] = ch;
            n += 1;
        }
    }
    if (n == 0) {
        const none = "none";
        const k = @min(none.len, buf.len);
        @memcpy(buf[0..k], none[0..k]);
        n = k;
    }
    return buf[0..n];
}

test "ident decode from a real RTL8211 ID (0x001c c916)" {
    const id = decodeIdent(0x001C, 0xC916);
    try std.testing.expectEqual(@as(u32, 0x0007_32), id.oui);
    try std.testing.expectEqual(@as(u16, 0x11), id.model); // 0xC916[9:4] = 0x11
    try std.testing.expectEqual(@as(u16, 0x6), id.revision);
    try std.testing.expectEqualStrings("Realtek", id.vendor());
}

test "ident decode from a Marvell 88E1512 ID (0x0141 0dd1)" {
    const id = decodeIdent(0x0141, 0x0DD1);
    try std.testing.expectEqual(@as(u32, 0x0050_43), id.oui);
    try std.testing.expectEqualStrings("Marvell", id.vendor());
}

test "unknown OUI falls back to unknown" {
    const id = decodeIdent(0x1234, 0x5678);
    try std.testing.expectEqualStrings("unknown", id.vendor());
}

test "autoneg intersection prefers 100 full duplex" {
    const local: u16 = anar_bits.tech_10_hd | anar_bits.tech_10_fd |
        anar_bits.tech_100_hd | anar_bits.tech_100_fd;
    try std.testing.expectEqual(LinkMode.m100_fd, negotiatedFromPar(local, local));
    // 对端只报 10M 全双工 → 交集是 10M FD。
    try std.testing.expectEqual(LinkMode.m10_fd, negotiatedFromPar(local, anar_bits.tech_10_fd));
    // 没有任何交集。
    try std.testing.expectEqual(LinkMode.unknown, negotiatedFromPar(anar_bits.tech_10_hd, anar_bits.tech_100_fd));
}

test "1000BASE-T status decode" {
    const ok: u16 = gb_t_status_bits.lp_1000_fd | gb_t_status_bits.local_rx_ok;
    try std.testing.expectEqual(LinkMode.m1000_fd, negotiated1000(ok));
    try std.testing.expectEqual(LinkMode.unknown, negotiated1000(gb_t_status_bits.lp_1000_fd));
}

test "bmsr caps string" {
    var buf: [64]u8 = undefined;
    const s = bmsrCaps(&buf, bmsr.cap_100_tx_fd | bmsr.cap_10_t_fd);
    try std.testing.expectEqualStrings("100TX-FD,10T-FD", s);
    var buf2: [64]u8 = undefined;
    try std.testing.expectEqualStrings("none", bmsrCaps(&buf2, 0));
}
