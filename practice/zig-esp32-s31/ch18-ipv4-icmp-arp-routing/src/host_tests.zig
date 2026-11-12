//! ch18-ipv4-icmp-arp-routing：主机侧单测入口。
//!
//! `zig build test` 只编译/运行这个文件。它**不**引用 `hw.zig`/`trap.zig`/
//! `start.zig`/`main.zig`/`selftest.zig`，所以可以在 x86_64 上跑，不需要
//! 开发板、不需要 root、不需要抓包权限。
//!
//! 被测试的五个模块都是纯逻辑、零 MMIO：
//!
//!   - `inet.zig`  地址解析/掩码/前缀匹配 + RFC 1071 校验和 + RFC 1624 增量更新；
//!   - `ipv4.zig`  首部编解码、分片、有界重组（乱序/重复/重叠/超时/淘汰）、PMTU；
//!   - `icmp.zig`  回显请求/应答、frag-needed 的编码与解析、应答策略；
//!   - `arp.zig`   28 字节报文、缓存状态机（incomplete/reachable/stale/delay/probe）、
//!                 老化、容量与淘汰、收到请求后回应答；
//!   - `route.zig` 最长前缀匹配、metric 决胜、connected vs gateway、表容量。
//!
//! 板侧那只自检（大报文分片 + 乱序重组 + ARP 状态机走一遍）在 `src/selftest.zig`，
//! 只能在板子上跑；两套测试的边界必须写清楚，不能互相冒充。

test {
    _ = @import("inet.zig");
    _ = @import("ipv4.zig");
    _ = @import("icmp.zig");
    _ = @import("arp.zig");
    _ = @import("route.zig");
}
