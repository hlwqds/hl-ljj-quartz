//! ch09-flash-partition-nvs：读分区表 → 找 storage → 扫描 KV → 追加 → 读回。
//!
//! `main` 由 `_start` 用 `call main` 直接进入（不是 IDF 的 `app_main`），
//! 所以符号名必须就是 `main`：`pub export fn main`，C 调用约定。
//!
//! 本章只做一条链路，顺序固定：
//!
//!   1. 从 `0x8000` 读 `0xC00` 字节分区表，逐条打印；
//!   2. 按标签找 `storage`（`0x300000` / `0x10000`）；
//!   3. 扫描它的第一个 4 KiB 扇区，得到已有的开机计数；
//!   4. 追加一条 `value = last_value + 1` 的记录，并读回比对；
//!   5. 重新扫描，确认“下次开机”能看到这条记录。
//!
//! 第 5 步才是验收的核心：`append` 返回成功只说明 ROM 报告完成，
//! 重新扫描能读回来才说明数据真的落在阵列里。
//!
//! 串口输出只依赖掩膜 ROM 的 `esp_rom_printf`（链接脚本 PROVIDE 到
//! 0x2f800024）；本章不自己配 UART，也不开中断。

const builtin = @import("builtin");

const flash = @import("flash.zig");
const partition = @import("partition.zig");
const kv = @import("kv.zig");

comptime {
    if (builtin.cpu.arch != .riscv32) {
        @compileError("ch09-flash-partition-nvs 必须交叉编译到 riscv32");
    }
    if (builtin.abi != .eabihf) {
        @compileError("ch09-flash-partition-nvs 需要 eabihf（硬浮点）ABI");
    }
}

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;

// ---------------------------------------------------------------------------
// 极简打印：与 ch08 相同的策略——ROM printf 的变参对 32 位整数最稳，
// 一次只打一个值，字符串用 %s 配 [*:0]const u8。
// ---------------------------------------------------------------------------
fn printStr(text: [*:0]const u8) void {
    _ = esp_rom_printf("%s", text);
}

fn printU32(v: u32) void {
    _ = esp_rom_printf("%u", @as(c_uint, v));
}

fn printHex32(v: u32) void {
    _ = esp_rom_printf("0x%x", @as(c_uint, v));
}

fn printLabel(label: []const u8) void {
    // label 字段 16 字节，含结尾 NUL 时最长 15 字符；这里再留 1 字节给
    // “恰好 16 字符且没有 NUL”的异常表，保证 buf[n] 永远可写。
    var buf: [17:0]u8 = undefined;
    const n = @min(label.len, 16);
    @memcpy(buf[0..n], label[0..n]);
    buf[n] = 0;
    _ = esp_rom_printf("%s", buf.ptr);
}

fn printEntry(index: usize, e: partition.Entry) void {
    printStr("  [");
    printU32(@intCast(index));
    printStr("] ");
    printLabel(e.labelSlice());
    printStr(" type=");
    printU32(e.part_type);
    printStr(" sub=");
    printHex32(e.subtype);
    printStr(" off=");
    printHex32(e.offset);
    printStr(" size=");
    printHex32(e.size);
    printStr("\n");
}

fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

pub export fn main() noreturn {
    printStr("\nch09-flash-partition-nvs | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    printStr("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");

    // -----------------------------------------------------------------------
    // 1) 分区表
    // -----------------------------------------------------------------------
    partition.load() catch {
        printStr("partition: read failed (0x8000/0xC00)\n");
        halt();
    };

    printStr("partition table @0x8000: ");
    printU32(@intCast(partition.count));
    printStr(" entries, md5=");
    if (partition.md5_present) {
        printStr("present\n");
    } else {
        printStr("absent\n");
    }

    var i: usize = 0;
    while (i < partition.count) : (i += 1) {
        if (partition.at(i)) |e| printEntry(i, e);
    }

    // -----------------------------------------------------------------------
    // 2) storage 分区
    // -----------------------------------------------------------------------
    const storage = partition.find("storage") orelse {
        printStr("partition: storage not found (partitions.csv 没被采用？)\n");
        halt();
    };

    if (storage.part_type != partition.type_data) {
        printStr("partition: storage is not a data partition\n");
        halt();
    }
    if (storage.offset % flash.sector_size != 0 or storage.size < flash.sector_size) {
        printStr("partition: storage offset/size not sector aligned\n");
        halt();
    }

    printStr("storage base=");
    printHex32(storage.offset);
    printStr(" size=");
    printHex32(storage.size);
    printStr("\n");

    // 明确声明边界：这块区域不是 IDF 的 NVS 格式，也从不指向 nvs/bootloader。
    printStr("kv: append-only log, NOT IDF-NVS compatible\n");

    // -----------------------------------------------------------------------
    // 3) 扫描
    // -----------------------------------------------------------------------
    const before = kv.scan(storage.offset) catch {
        printStr("kv: scan failed\n");
        halt();
    };

    printStr("kv: scan records=");
    printU32(@intCast(before.records));
    printStr(" last_value=");
    printU32(before.last_value);
    printStr(" torn=");
    printStr(if (before.torn) "1\n" else "0\n");

    // -----------------------------------------------------------------------
    // 4) 追加开机计数 + 1
    // -----------------------------------------------------------------------
    // 写满 256 条、或尾部撕裂时，append 会先压缩：擦扇区、把最新值
    // 写回槽 0。这一行让“压缩发生了”在串口上可见。
    if (before.full or before.torn) {
        printStr("kv: compaction: tail not writable, erase + rewrite slot 0\n");
    }

    const next_value = before.last_value + 1;
    const rec = kv.append(storage.offset, before, next_value) catch {
        printStr("kv: append failed (write/verify)\n");
        halt();
    };

    printStr("kv: append seq=");
    printU32(rec.seq);
    printStr(" value=");
    printU32(rec.value);
    printStr(" -> verify ok\n");

    // -----------------------------------------------------------------------
    // 5) 重新扫描：模拟“下一次开机”
    // -----------------------------------------------------------------------
    const after = kv.scan(storage.offset) catch {
        printStr("kv: rescan failed\n");
        halt();
    };

    printStr("kv: rescan records=");
    printU32(@intCast(after.records));
    printStr(" last_value=");
    printU32(after.last_value);
    printStr("\n");

    if (after.last_value != next_value) {
        printStr("kv: boot_count mismatch (expected ");
        printU32(next_value);
        printStr(")\n");
    } else {
        printStr("kv: boot_count ok\n");
    }

    printStr("done: power-cycle to see boot_count increment\n");

    // 一次性实验到此结束；停在这里，不再写 flash。
    halt();
}
