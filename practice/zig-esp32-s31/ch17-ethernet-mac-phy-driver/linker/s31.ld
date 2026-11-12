/*
 * ch17-ethernet-mac-phy-driver —— 形态 B 的链接脚本
 *
 * 骨架与 ch13 相同（SRAM-only 布局 + 两个 flash 装载段），本章只把**所有
 * 边界符号**都暴露出来：自检程序的第一件事就是把这些符号与 IDF 的
 * memory.ld.in 对照，任何一条不符都必须在启动时报告，而不是等到某次
 * 踩内存之后再猜。
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

    /* 第二个 flash 装载段 = DROM：少了它 bootloader 的 rom_index == 2 断言会挂。 */
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
     * 本章的 trace ring、自检计数器、压测状态都在这里。 */
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
