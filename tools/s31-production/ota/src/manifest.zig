//! S31 生产化切片 B：OTA 清单校验（唯一准入入口，纯逻辑）。
//!
//! 本模块是清单准入的**唯一**实现：`ota_plan.zig` 只负责 `otadata`
//! 选槽与槽状态机，不再导出任何清单解析或验签函数。
//! 准入顺序实现 `tools/s31-production/SPEC.md` §3.5，并显式要求尾随签名至少 64 B。
//!
//! 准入顺序（顺序本身是契约，前三步合称“结构检查”）：
//!
//!   1. 清单总长度 ≥ 44 B 头，magic 为 `S31M`；
//!   2. 尾随签名长度 ≥ 64 B；
//!   3. `image_len` 等于实际收到的镜像字节数；
//!   4. 版本单调：`candidate > current`，同版本按降级拒绝；
//!   5. 调用注入的 `Verifier`，传原始头字节、镜像切片、原始签名字节。
//!
//! **结构检查（1–3）或版本检查（4）失败时绝不调用 `Verifier`**：
//! 未通过结构/版本门槛的输入不应消耗验签算力，也不应让未验签的版本号
//! 参与任何策略判断。
//!
//! 本模块不 import `std`、不分配、不写 flash、不读时钟；不实现
//! SHA-256 / Ed25519，也不解释 `digest` 与签名算法。
//!
//! 清单布局（44 B 头 + 不透明签名）：
//!
//!   | 偏移   | 字段      | 说明                          |
//!   |--------|-----------|-------------------------------|
//!   | 0..4   | magic     | `S31M`                        |
//!   | 4..8   | version   | u32 LE，版本单调递增          |
//!   | 8..12  | image_len | u32 LE，镜像字节数            |
//!   | 12..44 | digest    | 32 B 摘要（本模块不解释）     |
//!   | 44..   | signature | 不透明签名字节，长度 ≥ 64 B   |

pub const header_len: usize = 4 + 4 + 4 + 32;
pub const min_signature_len: usize = 64;
pub const magic = [4]u8{ 'S', '3', '1', 'M' };

pub const Header = struct {
    version: u32,
    image_len: u32,
    digest: [32]u8,
};

pub const Error = error{
    /// 总长度不足 44 B，读不出头。
    ShortHeader,
    /// 头的 magic 不是 `S31M`。
    BadMagic,
    /// 头之后的不透明签名不足 64 B。
    SignatureTooShort,
    /// 头声明的 `image_len` 与实际镜像字节数不等。
    LengthMismatch,
    /// `candidate <= current`，同版本重放也按降级拒绝。
    Downgrade,
    /// 注入的 `Verifier` 返回 `false`。
    Rejected,
};

/// 可注入的清单校验器，只回答“可信 / 不可信”。
///
/// 回调拿到的是**原始字节**：`header` 恰好 44 B，`signature` 是清单尾部
/// 余下字节（≥ 64 B），`image` 是调用方给出的镜像切片。本模块不拼接、
/// 不截断、不解释签名；算法与密钥由后续密码学切片负责。
pub const Verifier = struct {
    ctx: ?*anyopaque = null,
    verifyFn: *const fn (
        ctx: ?*anyopaque,
        header: []const u8,
        image: []const u8,
        signature: []const u8,
    ) bool,

    pub fn verify(
        self: Verifier,
        header: []const u8,
        image: []const u8,
        signature: []const u8,
    ) bool {
        return self.verifyFn(self.ctx, header, image, signature);
    }
};

fn readU32Le(in: []const u8) u32 {
    return @as(u32, in[0]) |
        (@as(u32, in[1]) << 8) |
        (@as(u32, in[2]) << 16) |
        (@as(u32, in[3]) << 24);
}

fn magicIs(bytes: []const u8) bool {
    return bytes[0] == magic[0] and
        bytes[1] == magic[1] and
        bytes[2] == magic[2] and
        bytes[3] == magic[3];
}

/// 只解析 44 B 头，不要求签名存在；供上位机/工具单独读取元数据。
/// 生产准入请用 `validateCandidate`，它会先校验签名长度与镜像长度。
pub fn decodeHeader(bytes: []const u8) Error!Header {
    if (bytes.len < header_len) return error.ShortHeader;
    if (!magicIs(bytes[0..4])) return error.BadMagic;
    var digest: [32]u8 = undefined;
    @memcpy(&digest, bytes[12..header_len]);
    return .{
        .version = readU32Le(bytes[4..8]),
        .image_len = readU32Le(bytes[8..12]),
        .digest = digest,
    };
}

/// 清单的两段视图：44 B 头与尾随不透明签名。
pub const Parts = struct {
    header: []const u8,
    signature: []const u8,
};

/// 把清单切成“头 + 尾随签名”两段，长度不足时报错。
pub fn split(manifest: []const u8) Error!Parts {
    if (manifest.len < header_len) return error.ShortHeader;
    const signature = manifest[header_len..];
    if (signature.len < min_signature_len) return error.SignatureTooShort;
    return .{
        .header = manifest[0..header_len],
        .signature = signature,
    };
}

/// 候选镜像的生产准入检查（顺序见模块注释）。
///
/// 成功返回解析出的头；失败返回具体错误，且**只有**第 5 步会调用
/// `verifier`。判定通过不代表镜像已被本模块验证为“内容正确”：
/// 摘要比对/签名验证的结论完全来自注入的回调。
pub fn validateCandidate(
    verifier: Verifier,
    manifest_bytes: []const u8,
    image: []const u8,
    current_version: u32,
) Error!Header {
    // 这里刻意不调用 `split`，让“长度 → magic → 签名长度 → image_len”
    // 的顺序在准入路径上一目了然；`split` 仍作为独立工具函数供调用方使用。
    if (manifest_bytes.len < header_len) return error.ShortHeader;
    const header = try decodeHeader(manifest_bytes[0..header_len]);
    const signature = manifest_bytes[header_len..];
    if (signature.len < min_signature_len) return error.SignatureTooShort;
    if (@as(u64, header.image_len) != @as(u64, image.len)) return error.LengthMismatch;
    if (header.version <= current_version) return error.Downgrade;
    if (!verifier.verify(manifest_bytes[0..header_len], image, signature)) return error.Rejected;
    return header;
}
