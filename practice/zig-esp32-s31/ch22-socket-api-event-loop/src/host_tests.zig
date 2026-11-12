//! ch22-socket-api-event-loop：主机侧单测入口。
//!
//! `zig build test` 只编译/运行这个文件。它**不**引用 `hw.zig`/`trap.zig`/
//! `start.zig`/`main.zig`/`selftest.zig`，所以能在 x86_64 / Zig 0.17.1 上跑，
//! 不需要开发板、不需要网线、不需要 root。
//!
//! 三个被测试的模块全是纯逻辑：
//!
//!   - `netstub.zig` 段线格式（编码/解码/边界）+ 脚本重放的确定性；
//!   - `socket.zig`  FD 表、状态机、部分读写、EAGAIN、背压、以及
//!     “同一脚本两次投递指纹相同”；
//!   - `event.zig`   poll 就绪集、轮转公平、截断、超时轮、连接池两种策略。
//!
//! 板侧那一只自检（`src/selftest.zig`）复用同样的模块，在 rv32 上把
//! 十二条判据各走一遍；两套测试的边界必须写清楚：主机侧负责“边界值与
//! 策略组合”，板侧只负责“同一份代码在真实 SRAM 布局下能跑完并给出同样
//! 结论”。主机用例数**不**等于板侧判据数。

test {
    _ = @import("netstub.zig");
    _ = @import("socket.zig");
    _ = @import("event.zig");
}
