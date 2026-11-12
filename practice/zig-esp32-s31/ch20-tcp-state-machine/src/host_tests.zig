//! ch20-tcp-state-machine：主机侧单测入口。
//!
//! `zig build test` 只编译/运行这个文件。它**不**引用 `hw.zig`/`trap.zig`/
//! `start.zig`/`main.zig`/`selftest.zig`，所以能在 x86_64 / Zig 0.17.1 上跑，
//! 不需要开发板、不需要网线、不需要 root。
//!
//! 被测试的两个模块全是纯逻辑：
//!
//!   - `tcp.zig`       20 字节首部 + 选项（MSS/WS/SACK）的编解码、seq 回绕
//!                     比较、11 状态迁移、MSS 分段、RFC 6298 RTO、单段重传
//!                     计时器、重复 ACK/快速重传、有界乱序重组、TIME_WAIT；
//!   - `checksum.zig`  RFC 1071 反码和、伪首部、已知 TCP 向量、奇数字节。
//!
//! 板侧那一只自检（`src/selftest.zig`）会复用同样两个模块，在 rv32 上把
//! 十个注入场景各走一遍；两套测试的边界写在章节 20.10：主机侧证明“分支都
//! 对”，板侧证明“同一份机器码在真实 SRAM 布局下跑得完”。

test {
    _ = @import("tcp.zig");
    _ = @import("checksum.zig");
}
