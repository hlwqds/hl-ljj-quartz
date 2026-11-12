//! ch19-udp-dhcp-dns：主机侧单测入口。
//!
//! `zig build test` 只编译/运行这个文件。它**不**引用 `hw.zig`/`trap.zig`/
//! `start.zig`/`main.zig`/`selftest.zig`，所以能在 x86_64 / Zig 0.17.1 上跑，
//! 不需要开发板、不需要网线、不需要 root。
//!
//! 被测试的三个模块全是纯逻辑：
//!
//!   - `udp.zig`   8 字节首部、伪首部校验和、0/0xFFFF 规则、端口分派；
//!   - `dhcp.zig`  236+4+TLV 的编解码、DISCOVER/OFFER/REQUEST/ACK 状态机、
//!                 T1/T2 续租、NAK 回 INIT、重传退避；
//!   - `dns.zig`   头/问题编码、压缩指针解压（含环路防护）、A 记录解析、
//!                 TTL（含 RFC 2181 §8 最高位）缓存与淘汰。
//!
//! 板侧那一只自检（`src/selftest.zig`）会复用同样的模块，在 rv32 上把
//! “DISCOVER → ACK → 续租”和“查询 → 响应 → 缓存命中”各走一遍；两套测试
//! 的边界必须写清楚，不能互相冒充。

test {
    _ = @import("udp.zig");
    _ = @import("dhcp.zig");
    _ = @import("dns.zig");
}
