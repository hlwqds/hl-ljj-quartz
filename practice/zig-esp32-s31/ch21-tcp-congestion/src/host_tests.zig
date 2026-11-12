//! ch21-tcp-congestion：主机侧单测入口。
//!
//! `zig build test` 只编译/运行这个文件。它**不**引用 `hw.zig`/`trap.zig`/
//! `start.zig`/`main.zig`/`selftest.zig`，所以能在 x86_64 / Zig 0.17.1 上跑，
//! 不需要开发板、不需要网线、不需要 root。
//!
//! 被测试的两个模块全是纯逻辑：
//!
//!   - `cong.zig`  拥塞窗口状态机（慢启动 / 拥塞避免 / 快重传 / 快恢复 /
//!                 超时）、`ssthresh` 下限、窗口取小、RFC 7323 窗口缩放、
//!                 BDP、RFC 6298 RTT 估计、pacing 令牌桶、Nagle 判据、
//!                 Mathis 公式的整数开方；
//!   - `sim.zig`   确定性丢包仿真：无丢包曲线、同种子可复现、吞吐随丢包率
//!                 单调下降、rwnd 限速、与 Mathis 同量级。
//!
//! 板侧那一只自检（`src/selftest.zig`）复用同样的模块，在 rv32 上把十个判据
//! 各走一遍；两套测试的边界必须写清楚，不能互相冒充：主机侧负责“边界值
//! 与公式”，板侧只负责“同一份代码在真实 SRAM 布局下能跑完并给出同样结论”。

test {
    _ = @import("cong.zig");
    _ = @import("sim.zig");
}
