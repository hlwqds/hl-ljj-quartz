/*
 * ch23-tls-http —— 形态 B 的链接脚本
 *
 * 骨架与 ch13–ch22 相同（SRAM-only 布局 + 两个 flash 装载段），本章不改
 * 任何地址：TLS 记录层/密钥派生/DER/HTTP 解析都是纯逻辑，板侧只需要一块
 * 合法的 SRAM 放记录重组、证书与 HTTP 的工作缓冲。符号仍然全部暴露，
 * 方便链接期 ASSERT 复核边界。
 *
 * 与 ch19–ch22 唯一的布局差异：`.flash.rodata` 落在 0x40020040 而不是
 * 0x40020020，因为本章用 AES-128-GCM，rv32 上走 std 的软件查表，那五张表
 * 声明了 align(64)（std/crypto/aes/soft.zig:746-750），把整个 .rodata 的
 * 对齐抬到 64。bootloader 的真实约束是「页内偏移同余」
 * （esp_image_format.c:904），镜像里 paddr 与 vaddr 的 0x40 偏移一致，
 * 实测启动并跑完 12 条判据。
 *
 * 段布局（三段，两段在 flash）：
 *
 *     irom 0x40000020  .flash.text     esp_app_desc_t(256B) + .text.trap + .text
 *     drom 0x40020020  .flash.rodata   .rodata/.srodata
 *     sram 0x2F000000  .trap_ram       trap 入口（放 flash 会 CPU_LOCKUP_RESET）
 *                      .data           有初值可写数据（LMA == VMA）
 *                      .bss            NOBITS，_start 清零
 *                      [堆]            _heap_start == _bss_end, _heap_end == _stack_bottom
 *                      [栈 16 KiB]     _stack_bottom .. _stack_top，向下增长
 *
 * 三条不变的硬约束（真机实测，见 ../BRINGUP-2026-11-12.md）：
 *   1) bootloader 断言镜像里正好两个落在 0x40000000..0x44000000 的段
 *      （IROM + DROM），且 0x20 偏移；
 *   2) trap 向量必须落在 SRAM（.trap_ram）；
 *   3) 第一个装载段最前面是 256 字节 esp_app_desc_t。
 *
 * 地址来源（ESP-IDF v6.1）：
 *   components/esp_system/ld/esp32s31/memory.ld.in:19  SRAM_START = 0x2F000000
 *   components/esp_system/ld/esp32s31/memory.ld.in:23  SRAM_SIZE = SRAM_SEG_END - SRAM_START
 *   components/esp_system/ld/esp32s31/ld.hp_mem_defs    SRAM_SEG_END = 0x2F07AFC0
 * SRAM 物理上是 512 KiB（0x80000），末尾 0x5040 被二级 bootloader 的
 * iram_loader_seg 占着，应用可用到 0x2F07AFC0，长度 0x7AFC0。
 */

ENTRY(_start)

MEMORY
{
    irom (rx)  : ORIGIN = 0x40000020, LENGTH = 0x3F000
    drom (r)   : ORIGIN = 0x40020020, LENGTH = 0x3F000
    sram (rwx) : ORIGIN = 0x2F000000, LENGTH = 0x7AFC0
}

SECTIONS
{
    .flash.text : ALIGN(16)
    {
        /* bootloader 从镜像头 entry 跳到 _start；第一个装载段的第一批字节
         * 必须是 esp_app_desc_t（魔数 0xABCD5432，256 字节）。 */
        _image_start = .;
        KEEP(*(.app_desc))
        . = ALIGN(16);

        _text_start = .;

        /* mtvec.BASE 的低 2 位是模式位，必须 4 字节对齐。 */
        . = ALIGN(4);
        KEEP(*(.text.trap))
        . = ALIGN(4);

        *(.text .text.*)
        . = ALIGN(16);
        _text_end = .;
    } > irom

    /* 第二个 flash 装载段 = DROM：少了它 bootloader 的 rom_index == 2 断言会挂。
     *
     * 实际起点是 0x40020040，不是 ORIGIN(drom) = 0x40020020（本章实测）：
     * Zig/LLVM 产出的 `.rodata` 输入节自带 64 字节对齐（`readelf -SW` 里
     * Align=64）。来源是 std 的软件 AES 查表：`std/crypto/aes/soft.zig:746-750`
     * 里五张 S-box/LUT 都写了 `align(64)`（注释说明是为了让加解密用不同的
     * L1 cache line）。本章用 AES-128-GCM，rv32 上没有 AES 指令，所以这五张
     * 表进了 `.rodata`，把整节的对齐抬到 64；lld 于是把输出节推到 64 的
     * 整数倍，段起点比 drom 起点高 0x20。
     * bootloader 真正检查的不是“段必须落在 ORIGIN 上”，而是
     * 页内偏移同余：
     *     esp_image_format.c:904
     *     segment_data_offs % mmu_page_size == load_addr % mmu_page_size
     * elf2image 会插入填充段把 paddr 对齐到同样的 0x40，这条检查因此通过；
     * 板侧实测 12/12 全过，且 .rodata 里的字符串/已知答案都读得对。
     * 若强行把段压回 0x40020020（ALIGN(32)/SUBALIGN），等于削弱 LLVM 的
     * 对齐声明，本章不做这种“为了让地址好看”的降级。
     */
    .flash.rodata : ALIGN(16)
    {
        _rodata_start = .;
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(16);
        _rodata_end = .;
    } > drom

    /* trap 入口必须在 SRAM：放 flash 时异常投递直接 CPU_LOCKUP_RESET(0x1a)。 */
    .trap_ram : ALIGN(4)
    {
        _trap_start = .;
        KEEP(*(.trap_ram))
        . = ALIGN(4);
        _trap_end = .;
    } > sram

    /* 有初值的可写数据。本布局 LMA == VMA：_start 不需要搬运。 */
    .data : ALIGN(16)
    {
        _data_start = .;
        *(.data .data.*)
        /* RISC-V small-data anchor：gp = 当前 + 0x800。 */
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        . = ALIGN(16);
        _data_end = .;
    } > sram

    /* 零初始化数据：NOBITS，内容由 _start 清零。
     * 本章的静态工作区都在这里（合计约 11 KiB，实测 .bss = 0x2a70）：
     *   g_msg    3004 B  一条握手消息（4 字节头 + 3000 字节 body）
     *   g_wire   3300 B  分片后的记录流（5 字节头 + fragment）
     *   g_reasm  3200 B  跨记录重组缓冲
     *   g_cert    768 B  证书 fixture 的可写副本（篡改用）
     *   g_http    512 B  响应构造缓冲
     *   g_chunk    64 B  chunked 解码输出
     *   g_plain   128 B  AES-GCM 解密输出
     * 放 .bss 而不是栈上：主栈只有 16 KiB，11 KiB 的临时缓冲留在栈里会
     * 在 ECDSA 这类深调用里踩穿栈顶，表现为 trap 而非可归因的失败。 */
    .bss (NOLOAD) : ALIGN(16)
    {
        _bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        _bss_end = .;
    } > sram

    _data_load_start = LOADADDR(.data);
    _data_load_end = LOADADDR(.data) + SIZEOF(.data);

    /* ---------------------------------------------------------------------
     * 堆与栈的边界
     *
     * 主栈 16 KiB 放在 SRAM 最末尾（_start 里 `la sp, _stack_top`）。
     * 堆从 _bss_end 长到 _stack_bottom。自检会打印这四个边界，
     * 并检查 `_heap_start <= _heap_end`、`_bss_end <= _stack_bottom`。
     * ------------------------------------------------------------------- */
    _stack_size = 0x4000;
    _stack_top = ORIGIN(sram) + LENGTH(sram);
    _stack_bottom = _stack_top - _stack_size;

    _heap_start = _bss_end;
    _heap_end = _stack_bottom;

    /* 链接期就否决明显错误的布局，免得自检变成唯一的防线。 */
    ASSERT(_image_start == ORIGIN(irom),
        "first flash segment must start at ORIGIN(irom) = 0x40000020")
    ASSERT(_rodata_start >= ORIGIN(drom) && _rodata_end <= ORIGIN(drom) + LENGTH(drom),
        ".flash.rodata must live inside the drom window")
    ASSERT(_rodata_start % 64 == 0,
        ".flash.rodata must stay 64-byte aligned (LLVM .rodata input alignment)")
    ASSERT(_trap_start >= ORIGIN(sram) && _trap_end <= ORIGIN(sram) + LENGTH(sram),
        ".trap_ram must live inside SRAM")
    ASSERT(_bss_end <= _stack_bottom,
        "SRAM exhausted: .bss overlaps the 16 KiB main stack")
    ASSERT(_stack_top == ORIGIN(sram) + LENGTH(sram),
        "_stack_top must be the exclusive end of SRAM")

    /*
     * 掩膜 ROM 里的函数，用绝对地址提供：
     *   IDF v6.1 components/esp_rom/esp32s31/ld/esp32s31.rom.ld
     *     ets_printf   = 0x2f800024
     *     ets_delay_us = 0x2f80003c
     * ROM 区间 0x2F800000..0x2F850000（soc.h 的 SOC_IROM_MASK_LOW/HIGH），
     * 是独立的地址空间，不与应用 SRAM 顶端 0x2F07AFC0 冲突。
     */
    PROVIDE(esp_rom_printf = 0x2f800024);
    PROVIDE(esp_rom_delay_us = 0x2f80003c);
}
