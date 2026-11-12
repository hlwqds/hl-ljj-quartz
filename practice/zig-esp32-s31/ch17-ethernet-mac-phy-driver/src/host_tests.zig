//! ch17-ethernet-mac-phy-driver：主机侧单测入口。
//!
//! `zig build test` 只跑纯逻辑，不碰任何 MMIO：
//!
//!   descs.zig —— 32 字节增强描述符的字段偏移、OWN 位、帧长解码、环回绕；
//!   regs.zig  —— GMII 地址寄存器编码、MDC 分频选择；
//!   phy.zig   —— PHY ID 拆 OUI/型号/版本、自协商结果判定；
//!   pins.zig  —— RGMII 引脚表（不重复、方向数量）；
//!   hw.zig    —— 小端打包；
//!   emac.zig  —— 测试帧组装（最小帧填充到 60 字节）。
//!
//! 这些测试的价值不在“覆盖率”，而在于：**描述符布局与位域是上板后
//! 最难调试的东西**——OWN 位错一位，症状是“DMA 永远不碰描述符”，
//! 而在串口上完全看不出原因。先把它们钉在主机侧。

test {
    _ = @import("descs.zig");
    _ = @import("regs.zig");
    _ = @import("phy.zig");
    _ = @import("pins.zig");
    _ = @import("hw.zig");
    _ = @import("emac.zig");
}
