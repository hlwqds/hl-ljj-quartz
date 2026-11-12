//! ch23-tls-http：生成证书 fixture（`src/testdata/sample-cert.der`）。
//!
//! 为什么要有这个工具：`cert.zig` 的解析器必须对着**一份真实存在的 DER**
//! 干活，而不是对着自己刚构造的内存。把这份 DER 落盘之后，
//!   - `zig build test` 能验证「构造器产出的字节 == 落盘的那份」；
//!   - `zig build gen-fixture` 可以在证书字段变化时重新生成；
//!   - 板上 `@embedFile` 直接读它，自检里解析的就是这份字节。
//!
//! 字节完全确定：ECDSA 的密钥来自固定 seed（0x23 × 32），签名的 k 来自
//! 固定 noise（全零）。所以重跑这个工具不应产生任何 diff。
//!
//! 用法（仓库根或工程根都可以，路径相对工程根）：
//!   cd practice/zig-esp32-s31/ch23-tls-http && zig build gen-fixture

const std = @import("std");
const cert = @import("cert.zig");

pub fn main() !void {
    var buf: [cert.max_cert_len]u8 = undefined;
    const der = try cert.buildSelfSigned(&buf);

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "src/testdata/sample-cert.der",
        .data = der,
    });

    const fp = cert.fingerprint(der);
    std.debug.print("wrote src/testdata/sample-cert.der: {d} bytes\n", .{der.len});
    std.debug.print("sha256: {x}\n", .{&fp});
}
