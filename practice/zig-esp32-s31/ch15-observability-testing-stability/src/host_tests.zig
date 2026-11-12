//! ch15-observability-testing-stability：主机侧单测入口。
//!
//! `zig build test` 只编译/运行这个文件。它**不**引用 `hw.zig`/`trap.zig`/
//! `main.zig`，所以可以在 x86_64 上跑，不需要交叉工具链的运行时库。
//!
//! 被测试的两个模块都是纯逻辑：
//!   - `trace.zig`：时间戳环的覆盖、顺序、丢弃计数、格式化；
//!   - `watchdog.zig`：截止时间、边界（恰好等于 deadline）、喂狗与恢复计数。
//!
//! 设备侧自检（链接符号、寄存器、时钟校准）无法在主机上跑，它们由
//! `check.zig` 在真机上执行——两套测试的边界必须写清楚，不能互相冒充。

test {
    _ = @import("trace.zig");
    _ = @import("watchdog.zig");
}
