//! ch16-stack-architecture-zero-copy：主机侧单测入口。
//!
//! `zig build test` 只编译/运行这个文件。它**不**引用 `hw.zig`/`trap.zig`/
//! `start.zig`/`main.zig`，所以可以在 x86_64 上跑，不需要交叉工具链的运行时库，
//! 也不需要开发板、不需要 root、不需要 TAP。
//!
//! 被测试的五个模块都是纯逻辑：
//!
//!   - `pbuf.zig`       池分配、链、引用计数、`eat`（零拷贝剥首部）、`toLinear`；
//!   - `checksum.zig`   RFC 1071 求和、伪首部、RFC 1624 增量更新；
//!   - `headers.zig`    以太网/IPv4/UDP/TCP 首部的字节级编解码与严格校验；
//!   - `netif.zig`      MTU、输出路径、`sendPbuf` 的零拷贝/线性化边界、输入分派；
//!   - `timer_wheel.zig` 哈希时间轮的到期精度、取消、句柄复用与回绕。
//!
//! 设备侧的那只自检（真帧构造 + loopback + 打印判读行）在 `src/selftest.zig`，
//! 只能在板子上跑；两套测试的边界必须写清楚，不能互相冒充。

test {
    _ = @import("pbuf.zig");
    _ = @import("checksum.zig");
    _ = @import("headers.zig");
    _ = @import("netif.zig");
    _ = @import("timer_wheel.zig");
}
