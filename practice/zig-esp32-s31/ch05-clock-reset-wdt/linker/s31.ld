/*
 * ch05-clock-reset-wdt —— 形态 B 的最小链接脚本（SRAM-only 布局，沿用 ch04）
 *
 * 与 ch04 的脚本相比只多了两件事：
 *   1) 多导出一个 ROM 符号 rtc_get_reset_reason（复位原因由 ROM 判定）；
 *   2) 注释里补上本章用到的符号来源，方便逐项复核。
 * 段顺序、MEMORY 区间、栈顶与 .bss 边界与 ch04 完全一致——本章不动内存布局，
 * 只把“启动时默认成立的三件事”（时钟已配好、复位原因可读、看门狗不咬人）
 * 变成可观测、可控的代码。
 *
 * 地址来源：ESP-IDF v6.1 的 esp32s31 内存定义
 *   IDF_PATH/components/esp_system/ld/esp32s31/memory.ld.in
 * SRAM 段为 0x2F000000 .. SRAM_SEG_END（0x2F07AFC0），长度 0x7AFC0。
 */

ENTRY(_start)

MEMORY
{
    /* 真机发现（2026-11-12）：S31 bootloader（unpack_load_app）在
     * SOC_MMU_DI_VADDR_SHARED=1 下断言 rom_index == 2，要求镜像里正好有
     * 两个落在 0x40000000..0x44000000 的段（IROM + DROM）；只有 SRAM 段的
     * 镜像会 Assert failed。0x20 偏移与 IDF 一致（paddr%64K == vaddr%64K）。 */
    irom (rx)  : ORIGIN = 0x40000020, LENGTH = 0x3F000
    drom (r)   : ORIGIN = 0x40020020, LENGTH = 0x3F000
    sram (rwx) : ORIGIN = 0x2F000000, LENGTH = 0x7AFC0
}

SECTIONS
{
    .flash.text : ALIGN(16)
    {
        /* 第一个装载段必须以 esp_app_desc_t 开头（256 字节，魔数 0xABCD5432），
         * 大小与关键偏移由 src/start.zig 的 comptime 断言守住。 */
        _image_start = .;
        KEEP(*(.app_desc))
        . = ALIGN(16);

        _text_start = .;
        KEEP(*(.text.entry))
        *(.text .text.*)
        . = ALIGN(16);
        _text_end = .;
    } > irom

    /* 第二个 flash 装载段 = DROM：没有它 bootloader 的 rom_index == 2 断言会挂。 */
    .flash.rodata : ALIGN(16)
    {
        _rodata_start = .;
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(16);
        _rodata_end = .;
    } > drom

    /* 有初值的可写数据；本布局 LMA == VMA，_start 不需要搬运。 */
    .data : ALIGN(16)
    {
        _data_start = .;
        *(.data .data.*)
        /* RISC-V small-data anchor：符号放在 .sdata 之前，gp = 当前 + 0x800。 */
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        . = ALIGN(16);
        _data_end = .;
    } > sram

    /* 零初始化数据：NOBITS，镜像里只有地址与长度，内容由 _start 清零。 */
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

    _heap_start = _bss_end;
    _stack_top = ORIGIN(sram) + LENGTH(sram);

    /*
     * 掩膜 ROM 里的三个函数，用绝对地址提供：
     *   IDF_PATH/components/esp_rom/esp32s31/ld/esp32s31.rom.ld
     *     rtc_get_reset_reason = 0x2f800018
     *     ets_printf           = 0x2f800024
     *     ets_delay_us         = 0x2f80003c
     * PROVIDE 只在符号仍未定义时生效，不会覆盖真正的定义。
     */
    PROVIDE(rtc_get_reset_reason = 0x2f800018);
    PROVIDE(esp_rom_printf = 0x2f800024);
    PROVIDE(esp_rom_delay_us = 0x2f80003c);
}
