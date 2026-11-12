//! ch05-clock-reset-wdt：复位原因。
//!
//! 复位原因由**掩膜 ROM** 判定，不是应用自己推断的。S31 的 ROM 里有一个
//! `rtc_get_reset_reason(int cpu_no)`，IDF 的 `esp_rom_get_reset_reason()`
//! 就是它的别名：
//!   IDF_PATH/components/esp_rom/esp32s31/ld/esp32s31.rom.api.ld
//!     PROVIDE ( esp_rom_get_reset_reason = rtc_get_reset_reason );
//!   IDF_PATH/components/esp_rom/esp32s31/ld/esp32s31.rom.ld
//!     rtc_get_reset_reason = 0x2f800018;
//! 链接脚本用 `PROVIDE(rtc_get_reset_reason = 0x2f800018)` 把它接到这里，
//! 所以本模块不碰任何寄存器，只消费 ROM 的结论。
//!
//! 返回值是 soc_reset_reason_t 的编码：
//!   IDF_PATH/components/soc/esp32s31/include/soc/reset_reasons.h
//! 该文件同时给出了到 IDF 公开枚举 esp_reset_reason_t 的归类规则
//! （IDF_PATH/components/esp_system/port/soc/esp32s31/reset_reason.c）。
//! 两层都要打印：编码回答“具体是谁”，归类回答“对应用意味着什么”。

const rom_cpu0: c_int = 0;

extern fn rtc_get_reset_reason(cpu_no: c_int) c_int;

/// 结构化的一条复位原因记录。
pub const Info = struct {
    code: u32,
    /// soc_reset_reason_t 的名字（去掉公共前缀），便于对照头文件。
    name: [:0]const u8,
    /// 归到 IDF 的 esp_reset_reason_t；UNKNOWN 表示 IDF 也不归类。
    idf: [:0]const u8,
};

const table = [_]Info{
    .{ .code = 0x01, .name = "CHIP_POWER_ON", .idf = "ESP_RST_POWERON" },
    .{ .code = 0x03, .name = "CORE_SW", .idf = "ESP_RST_SW" },
    .{ .code = 0x05, .name = "CORE_DEEP_SLEEP / CORE_PMU_PWR_DOWN", .idf = "ESP_RST_DEEPSLEEP" },
    .{ .code = 0x06, .name = "CPU_PMU_PWR_DOWN", .idf = "ESP_RST_DEEPSLEEP" },
    .{ .code = 0x07, .name = "CORE_MWDT0", .idf = "ESP_RST_TASK_WDT" },
    .{ .code = 0x08, .name = "CORE_MWDT1", .idf = "ESP_RST_INT_WDT" },
    .{ .code = 0x09, .name = "CORE_RWDT", .idf = "ESP_RST_WDT" },
    .{ .code = 0x0B, .name = "CPU_MWDT", .idf = "ESP_RST_WDT" },
    .{ .code = 0x0C, .name = "CPU_SW (CPU0_SW)", .idf = "ESP_RST_SW" },
    .{ .code = 0x0D, .name = "CPU_RWDT", .idf = "ESP_RST_WDT" },
    .{ .code = 0x0F, .name = "SYS_BROWN_OUT", .idf = "ESP_RST_BROWNOUT" },
    .{ .code = 0x10, .name = "SYS_RWDT", .idf = "ESP_RST_WDT" },
    .{ .code = 0x12, .name = "SYS_SUPER_WDT", .idf = "ESP_RST_WDT" },
    .{ .code = 0x13, .name = "CORE_PWR_GLITCH", .idf = "ESP_RST_PWR_GLITCH" },
    .{ .code = 0x14, .name = "CORE_EFUSE_CRC", .idf = "ESP_RST_EFUSE" },
    .{ .code = 0x16, .name = "CORE_USB_JTAG", .idf = "ESP_RST_USB" },
    .{ .code = 0x17, .name = "CORE_USB_UART", .idf = "ESP_RST_USB" },
    .{ .code = 0x18, .name = "CPU_JTAG", .idf = "ESP_RST_JTAG" },
    .{ .code = 0x1A, .name = "CPU_LOCKUP", .idf = "ESP_RST_CPU_LOCKUP" },
};

/// ROM 判定出的原始编码。cpu_no 参数用 0（PRO_CPU），与 IDF 的 PRO_CPU_NUM 一致。
pub fn read() u32 {
    // ROM 函数返回 C 枚举（int）。用 bitCast 而不是 intCast：即使 ROM 返回了
    // 表外的值，也不要让转换本身引发 panic 语义。
    return @bitCast(rtc_get_reset_reason(rom_cpu0));
}

/// 查表；表外的编码原样返回 UNKNOWN，并在打印时把十六进制编码一起给出。
pub fn info(code: u32) Info {
    for (table) |entry| {
        if (entry.code == code) return entry;
    }
    return .{ .code = code, .name = "UNKNOWN", .idf = "ESP_RST_UNKNOWN" };
}

/// 常见复位原因的一句话说明，用来解释“看到这个说明上一轮发生了什么”。
pub fn hint(code: u32) [:0]const u8 {
    return switch (code) {
        0x01 => "上电或复位键，属于冷启动",
        0x03 => "软件复位了整个数字系统",
        0x05, 0x06 => "睡眠/掉电唤醒，本章不进入睡眠",
        0x07 => "MWDT0 超时（IDF 的 task WDT 用这一路）",
        0x08 => "MWDT1 超时（IDF 的 interrupt WDT 用这一路）",
        0x09, 0x0D, 0x10 => "RTC WDT 超时：有代码超过喂狗周期",
        0x0B => "MWDT 复位了 CPU：多半是长延时/死循环没喂狗",
        0x0C => "只复位了 CPU（例如通过 ROM 的 CPU 复位接口）",
        0x0F => "欠压：供电或负载瞬变",
        0x12 => "超级看门狗（SWD）复位",
        0x13 => "电源毛刺",
        0x14 => "eFuse CRC 校验失败",
        0x16, 0x17 => "USB Serial/JTAG 侧发起的复位",
        0x18 => "JTAG 复位命令",
        0x1A => "CPU lockup：异常处理里又出了异常",
        else => "未在 soc_reset_reason_t 中定义",
    };
}
