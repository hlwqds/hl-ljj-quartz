//! ch26-wifi-connection-wpa2-wpa3：判据用的常数表。
//!
//! 每个常数都有出处，两类：
//!
//!   * **公开标准向量**：RFC 6070 §2（PBKDF2-HMAC-SHA1）、passphrase
//!     "password" / SSID "IEEE" 的 WPA2 PSK（802.11i Annex H.4 的派生，
//!     hostap 生态里长期沿用的示例向量）。
//!   * **本工程固定输入的交叉实现值**：`tools/vectors.py`（CPython
//!     hashlib/hmac）算出，与 `src/wpa2.zig` / `src/sae.zig` 的 Zig 实现
//!     逐字节对拍。两套实现独立，写错就对不上。
//!
//! 十六进制字面量在编译期解码（`hex`），所以打错一个字符是编译错误，
//! 不是运行期的静默差异。

fn nibble(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("不是十六进制字符: " ++ .{c}),
    };
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    comptime {
        if (s.len % 2 != 0) @compileError("十六进制字面量必须是偶数长度");
    }
    var out: [s.len / 2]u8 = undefined;
    for (0..s.len / 2) |i| {
        out[i] = (nibble(s[2 * i]) << 4) | nibble(s[2 * i + 1]);
    }
    return out;
}

// ---------------------------------------------------------------------------
// RFC 6070 §2：PBKDF2-HMAC-SHA1(P="password", S="salt")
// ---------------------------------------------------------------------------

pub const rfc6070_c1: [20]u8 = hex("0c60c80f961f0e71f3a9b524af6012062fe037a6");
pub const rfc6070_c2: [20]u8 = hex("ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957");
pub const rfc6070_c4096: [20]u8 = hex("4b007901b765489abead49d926f721d065a429c1");
pub const rfc6070_long: [25]u8 = hex("3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038");

// ---------------------------------------------------------------------------
// 802.11i Annex H.4：PBKDF2(P="password", S="IEEE", 4096, 32) = PSK
// ---------------------------------------------------------------------------

pub const pmk_ieee: [32]u8 = hex("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e");

// ---------------------------------------------------------------------------
// PRF 的输入：AP/STA 的 MAC 故意让 STA 更大，逼实现做 Min/Max 重排
// ---------------------------------------------------------------------------

pub const ap_mac: [6]u8 = hex("021122334455");
pub const sta_mac: [6]u8 = hex("02aabbccddee");
pub const anonce: [32]u8 = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
pub const snonce: [32]u8 = hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f");

// ---------------------------------------------------------------------------
// PTK：PRF-384 与 PRF-512 对同一组输入
// ---------------------------------------------------------------------------

pub const ptk48: [48]u8 =
    hex("0cb59d207218375a0cc1c4db3cc0736060aad631553eee9dad2e06711528a2e8" ++
        "933ef3ea575a37b1ccce47a080b20de1");
pub const ptk64: [64]u8 =
    hex("0cb59d207218375a0cc1c4db3cc0736060aad631553eee9dad2e06711528a2e8" ++
        "933ef3ea575a37b1ccce47a080b20de18c7d6b7bc7b4c9bf71f755e381e79f3c");
pub const kck16: [16]u8 = hex("0cb59d207218375a0cc1c4db3cc07360");

// ---------------------------------------------------------------------------
// EAPOL-Key msg2：key_info=0x010a（ver=2 | pairwise | MIC）、replay=1、
// nonce=SNonce、key data=标准 RSN IE（22 字节）、MIC 已回填。
// 帧长 4 + 95 + 22 = 121。
// ---------------------------------------------------------------------------

pub const rsn_ie: [22]u8 = hex("30140100000fac040100000fac040100000fac020000");

pub const eapol_msg2: [121]u8 = hex(
    "02030075" ++ // EAPOL 头：v2, type=3, body=117
        "02" ++ // descriptor type = RSN
        "010a" ++ // key info
        "0000" ++ // key length
        "0000000000000001" ++ // replay counter = 1
        "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f" ++ // SNonce
        "00000000000000000000000000000000" ++ // IV
        "0000000000000000" ++ // RSC
        "0000000000000000" ++ // key ID
        "73e895d1efbcfc3c240b8752b08f41ea" ++ // MIC
        "0016" ++ // key data length = 22
        "30140100000fac040100000fac040100000fac020000",
);

pub const eapol_msg2_mic: [16]u8 = hex("73e895d1efbcfc3c240b8752b08f41ea");

// ---------------------------------------------------------------------------
// SAE（group 19 / P-256）固定输入
// ---------------------------------------------------------------------------

pub const sae_password = "correct horse battery staple";

pub const sae_pwd_seed_1: [32]u8 = hex("63ab6f8392ff2824d8a75c9c403bfab5236ee87311808791fd1de89a151fc2e7");
pub const sae_pwd_seed_2: [32]u8 = hex("28b74f836a38f8873180135ad68e8e6ffaf76f7df679d100b989b6769a0de406");
pub const sae_pwd_value_1: [32]u8 = hex("559ea05d3c0ff84d26d110202680503ee2d736cdf11ea82e92ddb961b4328ef9");

/// 「EC 替身」：真实实现里这是 K 的 x 坐标（scalar-op(rand, ...) 的结果）。
pub const sae_k: [32]u8 = hex("8f2c1d4b7a9e63550c4b3a291807f6e5d4c3b2a1908f7e6d5c4b3a29180f7e6d");
pub const sae_scalar_own: [32]u8 = hex("7b1f4c2a9d3e50618273a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9");
pub const sae_element_own: [64]u8 =
    hex("3c6ef372fe94f82be5a1d4c3b2a1908f7e6d5c4b3a29180f7e6d5c4b3a29180e" ++
        "9d0c1b2a3f4e5d6c7b8a99887766554433221100ffeeddccbbaa998877665544");
pub const sae_scalar_peer: [32]u8 = hex("1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f801");
pub const sae_element_peer: [64]u8 =
    hex("5a4b3c2d1e0f00112233445566778899aabbccddeeff00112233445566778899" ++
        "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100");

pub const sae_scalar_sum: [32]u8 = hex("954a8877fbadc0e31517597b9dbfe1022446688aacced0f31537597b9dbfe0fa");
pub const sae_keyseed: [32]u8 = hex("a9e90d74962c362eb32de5a283b6769d2abd397837fdf5b66b2b00c0d0741cc9");
pub const sae_kck: [32]u8 = hex("047c1f688fc5fe70b32d1d4b063b8acef284df930c16c6d213bb5f866c79046a");
pub const sae_pmk: [32]u8 = hex("d22b52d05c699fa37d0d7c8de70fa30a2f63e4d924b194ef59f7ca650d2d6702");
pub const sae_pmkid: [16]u8 = hex("954a8877fbadc0e31517597b9dbfe102");
pub const sae_confirm_own: [32]u8 =
    hex("6a643b15ba978398a4ce707bc8fa324ad3a749a69084eb51d4ef7911371043e3");
pub const sae_confirm_peer: [32]u8 =
    hex("6cdc0a4e16a4007fa0c5758acb555113c3be9583942c7d31ff6d1b481450fdbc");

// ---------------------------------------------------------------------------
// P-256 基域归约的边界用例（输入 >= p 才真的走到减法）
// ---------------------------------------------------------------------------

pub const modp_all_ff_out: [32]u8 = hex("00000000fffffffeffffffffffffffffffffffff000000000000000000000000");
pub const modp_p: [32]u8 = hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff");
pub const modp_p_plus_1: [32]u8 =
    hex("ffffffff00000001000000000000000000000001000000000000000000000000");
pub const modp_p_plus_x: [32]u8 =
    hex("ffffffff00000001000000000000000000000001000000000123456789abcdee");
pub const modp_p_plus_x_out: [32]u8 =
    hex("0000000000000000000000000000000000000000000000000123456789abcdef");
pub const two_255: [32]u8 = hex("8000000000000000000000000000000000000000000000000000000000000000");

// ---------------------------------------------------------------------------
// F_q 加法的溢出用例：0xff..ff + 0x00..01 = 2^256（carry 进第 257 位）。
// 这是唯一会让 reduceWide 的 remainder 触到 2^256 的路径，也是最容易写错
// （忘记把借位记到 r[0]）的地方。期望值 = 2^256 mod q。
// ---------------------------------------------------------------------------

pub const modq_all_ff: [32]u8 =
    hex("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
pub const modq_one: [32]u8 = hex("0000000000000000000000000000000000000000000000000000000000000001");
pub const modq_overflow_out: [32]u8 =
    hex("00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf");
