//! ch24-mqtt-ota-application-protocols：OTA 镜像清单校验 + A/B 回滚状态机。
//!
//! 这一层回答两个问题，两个都能在**不写 flash** 的前提下判定：
//!
//!   1) **这份镜像能不能信**：清单里写着“它是第几版、多长、内容摘要、
//!      由谁签的”。校验顺序是 /长度 → SHA-256 → Ed25519 签名/，
//!      任何一步失败都不许进 A/B 状态机；
//!   2) **验过了但跑不起来怎么办**：新槽位先以 `pending_verify` 启动，
//!      应用自检通过就 `markValid`；连续失败次数超预算就标 `invalid`，
//!      下一次启动回滚到旧槽位。
//!
//! 与真机的对应关系（都是 IDF 里的既有语义，本章只建模、不代实现）：
//!
//!   | 本章模型            | IDF v6.1 真实对应                                             |
//!   | ------------------- | ------------------------------------------------------------- |
//!   | `esp_ota_end()` 的  | `ota_verify_partition()` → `esp_image_verify()`                |
//!   | 镜像校验            | `esp_ota_ops.c:587`、`esp_image_format.c:360`                  |
//!   | 清单里的 256 B 描述 | `esp_app_desc_t`（`esp_app_desc.h:21` 的魔数 0xABCD5432）      |
//!   | `pending_verify`    | `ESP_OTA_IMG_PENDING_VERIFY`（`esp_flash_partitions.h:69`）    |
//!   | 连击失败 → 回滚     | `esp_ota_mark_app_invalid_rollback_and_reboot()`（头文件 :382）|
//!   | 自检通过 → 确认     | `esp_ota_mark_app_valid_cancel_rollback()`（头文件 :358）      |
//!
//! **本章不写 flash**：`slots` 是两个内存结结构体，`otadata` 的 CRC 与
//! 双副本选择规则只作为注释出现。真做 OTA 需要 ch09（分区表/flash 写入）
//! 与 ch17（链路）都闭环，判据见章节 24.11。
//!
//! 签名用的是 `std.crypto.sign.Ed25519`：rv32 上没有加速指令，验签走
//! Edwards25519 的软件标量乘，一次验签在 40 MHz 上约几百毫秒——所以
//! 板侧自检只验两次（正例 + 反例），不循环。

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{
    BufferTooSmall,
    BadMagic,
    Malformed,
    LengthMismatch,
    Sha256Mismatch,
    BadSignature,
    UntrustedKey,
    Downgrade,
    NotStaged,
    SlotIsActive,
};

/// 清单的线上长度：4 魔数 + 4 版本 + 4 长度 + 32 摘要 + 64 签名。
pub const manifest_len: usize = 4 + 4 + 4 + 32 + 64;

/// 签名覆盖的字节数：魔数 + 版本 + 长度 + 摘要（签名本身不在内）。
pub const signed_len: usize = 44;

/// 清单魔数："S31O"（S31 OTA）。选 ASCII 而不是随机数，是为了在
/// 十六进制转储里一眼能看出“这是一份清单，不是固件”。
pub const manifest_magic = [4]u8{ 'S', '3', '1', 'O' };

/// 固件描述结构（`esp_app_desc_t`）在镜像里的长度与魔数。
/// 真实 OTA 的第一道校验就是这两样（`esp_app_desc.h:21`）。
pub const app_desc_len: usize = 256;
pub const app_desc_magic: u32 = 0xABCD5432;

/// RFC 8032 §7.1 TEST 1 的种子与公钥。
///
/// 用规范向量而不是随手编的密钥，是为了让“签名能验过”本身成为一条已知
/// 答案：种子、公钥、消息、签名四个量都在 RFC 里写死，主机测试可以逐字节
/// 对拍。板侧只保留公钥（`trusted_key`）；`trust_seed` 只出现在
/// `seal()`（造 fixture 用）与测试里，真机上它不该存在。
pub const trust_seed = [32]u8{
    0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60,
    0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c, 0xc4,
    0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19,
    0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae, 0x7f, 0x60,
};

pub const trusted_key = [32]u8{
    0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7,
    0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64, 0x07, 0x3a,
    0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa6, 0x23, 0x25,
    0xaf, 0x02, 0x1a, 0x68, 0xf7, 0x07, 0x51, 0x1a,
};

// ---------------------------------------------------------------------------
// 清单
// ---------------------------------------------------------------------------

pub const Manifest = struct {
    version: u32,
    image_len: u32,
    sha256: [32]u8,
    signature: [64]u8,
};

fn writeU32Le(out: []u8, v: u32) void {
    out[0] = @intCast(v & 0xFF);
    out[1] = @intCast((v >> 8) & 0xFF);
    out[2] = @intCast((v >> 16) & 0xFF);
    out[3] = @intCast((v >> 24) & 0xFF);
}

fn readU32Le(in: []const u8) u32 {
    return @as(u32, in[0]) |
        (@as(u32, in[1]) << 8) |
        (@as(u32, in[2]) << 16) |
        (@as(u32, in[3]) << 24);
}

pub fn encodeManifest(out: []u8, m: Manifest) Error!usize {
    if (out.len < manifest_len) return error.BufferTooSmall;
    @memcpy(out[0..4], &manifest_magic);
    writeU32Le(out[4..8], m.version);
    writeU32Le(out[8..12], m.image_len);
    @memcpy(out[12..44], &m.sha256);
    @memcpy(out[44..108], &m.signature);
    return manifest_len;
}

pub fn decodeManifest(bytes: []const u8) Error!Manifest {
    if (bytes.len < manifest_len) return error.Malformed;
    if (!std.mem.eql(u8, bytes[0..4], &manifest_magic)) return error.BadMagic;
    var sha: [32]u8 = undefined;
    @memcpy(&sha, bytes[12..44]);
    var sig: [64]u8 = undefined;
    @memcpy(&sig, bytes[44..108]);
    return .{
        .version = readU32Le(bytes[4..8]),
        .image_len = readU32Le(bytes[8..12]),
        .sha256 = sha,
        .signature = sig,
    };
}

/// 造一份清单（“服务器侧”做的事）。板侧只在自检里用它生成 fixture；
/// 真机上的签名必须在构建流水线里完成，私钥永远不进固件。
pub fn seal(out: []u8, version: u32, image: []const u8, seed: [32]u8) Error!usize {
    if (out.len < manifest_len) return error.BufferTooSmall;
    const image_len: u32 = std.math.cast(u32, image.len) orelse return error.Malformed;

    const kp = Ed25519.KeyPair.generateDeterministic(seed) catch return error.BadSignature;
    var digest: [32]u8 = undefined;
    Sha256.hash(image, &digest, .{});

    var body: [signed_len]u8 = undefined;
    @memcpy(body[0..4], &manifest_magic);
    writeU32Le(body[4..8], version);
    writeU32Le(body[8..12], image_len);
    @memcpy(body[12..44], &digest);

    const sig = kp.sign(&body, null) catch return error.BadSignature;
    const sig_bytes = sig.toBytes();

    return encodeManifest(out, .{
        .version = version,
        .image_len = image_len,
        .sha256 = digest,
        .signature = sig_bytes,
    });
}

/// 校验清单 + 镜像。成功返回解出来的清单，失败返回**具体**原因——
/// “签名错”与“摘要错”必须能分开报，否则回滚决策没有依据。
pub fn verify(bytes: []const u8, image: []const u8) Error!Manifest {
    const m = try decodeManifest(bytes);

    // 1) 长度：清单声明的长度必须与实际收到的字节数一致。
    //    真实 OTA 里这一条对应 esp_ota_end 对 wrote_size 的检查。
    if (m.image_len != image.len) return error.LengthMismatch;

    // 2) 摘要：防传输损坏 / 半包。SHA-256 只证明“内容没变”，不证明“来源”。
    var digest: [32]u8 = undefined;
    Sha256.hash(image, &digest, .{});
    if (!std.mem.eql(u8, &digest, &m.sha256)) return error.Sha256Mismatch;

    // 3) 签名：证明“这份清单是持私钥的人签的”。签名覆盖 [0,44)，
    //    所以改了版本号或长度也会让签名失效——这一点必须与摘要分开测，
    //    否则“改版本号”这类攻击会被 SHA-256 那一关漏掉（摘要只覆盖 image）。
    const pk = Ed25519.PublicKey.fromBytes(trusted_key) catch return error.UntrustedKey;
    const sig = Ed25519.Signature.fromBytes(m.signature);
    sig.verify(bytes[0..signed_len], pk) catch return error.BadSignature;

    return m;
}

/// 版本单调性。降级攻击（把旧固件塞回设备绕过漏洞修复）只能靠版本号拦，
/// 摘要和签名都会对“旧但合法”的镜像说 OK。
pub fn checkVersion(current: u32, candidate: u32) Error!void {
    if (candidate <= current) return error.Downgrade;
}

// ---------------------------------------------------------------------------
// A/B 槽位与回滚（内存模型）
// ---------------------------------------------------------------------------

pub const Slot = enum(u1) { a = 0, b = 1 };

pub fn otherSlot(s: Slot) Slot {
    return if (s == .a) .b else .a;
}

/// 与 `esp_ota_img_states_t`（`esp_flash_partitions.h:67-74`）一一对应：
/// NEW → PENDING_VERIFY → VALID / INVALID / ABORTED。
pub const SlotState = enum(u8) {
    new = 0x0,
    pending_verify = 0x1,
    valid = 0x2,
    invalid = 0x3,
    aborted = 0x4,
    undefined_ = 0xFF,
};

pub const AbConfig = struct {
    /// 允许在 `pending_verify` 状态下启动几次。超过即判 aborted。
    /// 真实的 `otadata` 用一个 32 位 state 字段存，语义相同。
    max_boot_attempts: u8 = 2,
    /// 运行期连续失败次数预算（应用自检失败 / 看门狗复位 / 关键任务挂死）。
    max_runtime_failures: u8 = 3,
};

pub const SlotInfo = struct {
    state: SlotState = .undefined_,
    boot_attempts: u8 = 0,
    failures: u8 = 0,
};

pub const Rollback = struct {
    active: Slot = .a,
    slots: [2]SlotInfo = .{ .{ .state = .valid }, .{ .state = .undefined_ } },
    cfg: AbConfig = .{},
    /// 读数：发生过几次回滚（自检会打印）。
    rollbacks: u8 = 0,

    pub fn init(cfg: AbConfig) Rollback {
        return .{ .cfg = cfg };
    }

    pub fn activeState(self: *const Rollback) SlotState {
        return self.slots[@backingInt(self.active)].state;
    }

    /// 把新镜像写进“非活动槽”（真实实现里是 `esp_ota_begin/esp_ota_write`
    /// 写到另一个分区）。这里只翻状态位：新镜像还没启动过，所以是 NEW。
    pub fn stage(self: *Rollback, target: Slot) Error!void {
        if (target == self.active) return error.SlotIsActive;
        self.slots[@backingInt(target)] = .{ .state = .new };
    }

    /// 设下一次启动的槽位（真实实现是 `esp_ota_set_boot_partition`，写 otadata）。
    pub fn setBootSlot(self: *Rollback, target: Slot) Error!void {
        const st = self.slots[@backingInt(target)].state;
        if (st != .new and st != .pending_verify) return error.NotStaged;
        self.active = target;
        self.slots[@backingInt(target)] = .{ .state = .pending_verify, .boot_attempts = 1 };
    }

    /// 应用自检通过 → 确认（`esp_ota_mark_app_valid_cancel_rollback`）。
    pub fn markValid(self: *Rollback) void {
        const s = &self.slots[@backingInt(self.active)];
        s.state = .valid;
        s.boot_attempts = 0;
        s.failures = 0;
    }

    /// 运行期一次失败（自检某条不通过、看门狗复位、关键任务崩）。
    ///
    /// 只有**连续**失败才计入预算：`markValid()` 或在两次失败之间成功
    /// 完成一轮自检时调用 `noteHealthy()` 会把计数清零。这一点与 ch05 的
    /// 看门狗策略对齐：看门狗只负责“把死循环变成一次复位”，
    /// 计数与决策必须由应用自己做，否则“偶发一次超时”就会把好固件回滚掉。
    pub fn noteFailure(self: *Rollback) void {
        const s = &self.slots[@backingInt(self.active)];
        s.failures +|= 1;
        if (s.failures >= self.cfg.max_runtime_failures and s.state == .pending_verify) {
            s.state = .invalid;
            self.rollback();
        }
    }

    pub fn noteHealthy(self: *Rollback) void {
        self.slots[@backingInt(self.active)].failures = 0;
    }

    /// 模拟一次复位后的启动计数（真实实现里由 bootloader 读 otadata 完成）。
    ///
    /// 语义与 bootloader 一致：处于 `pending_verify` 的槽位每启动一次计数 +1，
    /// 超过预算仍未被确认 → `aborted` + 回滚。`valid` 槽位不计数。
    pub fn onBoot(self: *Rollback) void {
        const s = &self.slots[@backingInt(self.active)];
        switch (s.state) {
            .pending_verify => {
                s.boot_attempts +|= 1;
                if (s.boot_attempts > self.cfg.max_boot_attempts) {
                    s.state = .aborted;
                    self.rollback();
                }
            },
            else => {},
        }
    }

    /// 回滚到另一个槽。
    ///
    /// 真实实现要求另一个槽在 otadata 里是 VALID（否则没有可启动的镜像，
    /// bootloader 会停在 “no bootable app partitions”）。内存模型退一步：
    /// 只要它不是本次失败的槽，就把它当 VALID——因为本章的槽位从来只由
    /// 本状态机写入，`undefined_` 只出现在“B 从未写过”的初始态。
    pub fn rollback(self: *Rollback) void {
        self.active = otherSlot(self.active);
        const s = &self.slots[@backingInt(self.active)];
        if (s.state != .valid) s.state = .valid;
        s.boot_attempts = 0;
        self.rollbacks += 1;
    }
};
