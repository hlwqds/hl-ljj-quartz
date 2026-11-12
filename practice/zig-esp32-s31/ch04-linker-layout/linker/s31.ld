/*
 * ch04-linker-layout —— 形态 B 的最小链接脚本（代码在 flash 窗口，数据在 SRAM）
 *
 * 真机发现（2026-11-12）：S31 的 bootloader（bootloader_utility.c:
 * unpack_load_app）在 SOC_MMU_DI_VADDR_SHARED=1 下断言 rom_index == 2——
 * 镜像里**必须正好有两个**落在 0x40000000..0x44000000 的段（IROM + DROM），
 * 只有 SRAM 段的镜像会直接
 *   Assert failed in unpack_load_app ... (rom_index == 2)
 * 因此本版把 .text 放进 irom_seg（0x40000020）、.rodata 放进 drom_seg
 * （0x40020020），.data/.bss/栈留在 SRAM（0x2F000000）。
 *
 * 这两段由二级 bootloader 配好 MMU 后再跳进 _start，所以取指经过 cache；
 * .data 作为独立装载段由 bootloader 搬进 SRAM，_start 不搬。
 *
 * 地址来源：ESP-IDF v6.1 的 esp32s31 内存定义
 *   IDF_PATH/components/esp_system/ld/esp32s31/memory.ld.in
 * 其中 SRAM 段为 0x2F000000 .. SRAM_SEG_END（0x2F07AFC0），长度 0x7AFC0。
 * 本文件只抄录这个区间；段布局是本工程自己写的，不复制 IDF 的链接脚本。
 * S31 的 TRM 仍是 Pre-release v0.7，手册转正后逐项复核。
 */

ENTRY(_start)

MEMORY
{
    /* 0x20 偏移与 IDF 一致：让 paddr % 64KB == vaddr % 64KB。 */
    irom (rx)  : ORIGIN = 0x40000020, LENGTH = 0x3F000
    drom (r)   : ORIGIN = 0x40020020, LENGTH = 0x3F000
    sram (rwx) : ORIGIN = 0x2F000000, LENGTH = 0x7AFC0
}

SECTIONS
{
    /* 第一个装载段 = IROM：app_desc 在最前，其后是代码。 */
    .flash.text : ALIGN(16)
    {
        /*
         * 第一个装载段必须以 esp_app_desc_t 开头：256 字节、魔数 0xABCD5432。
         * 它不是“可选元数据”，而是 IDF bootloader 识别应用的入口信息，
         * 所以必须排在 .text 的所有内容之前。大小由 src/start.zig 的
         * comptime 断言保证（@sizeOf(AppDesc) == 256）。
         */
        _image_start = .;
        KEEP(*(.app_desc))
        . = ALIGN(16);

        _text_start = .;
        KEEP(*(.text.entry))
        *(.text .text.*)
        . = ALIGN(16);
        _text_end = .;
    } > irom

    /* 第二个 flash 装载段 = DROM：常量不加 .rodata 前缀就落进 SRAM，会少一段。 */
    .flash.rodata : ALIGN(16)
    {
        _rodata_start = .;
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(16);
        _rodata_end = .;
    } > drom

    /* 有初值的可写数据。本布局 LMA == VMA：_data_load_start == _data_start。 */
    .data : ALIGN(16)
    {
        _data_start = .;
        *(.data .data.*)
        /* RISC-V small-data anchor：链接器 relaxation 可能生成 gp 相对访问。
         * 与 IDF ld.dram.sections 同款：符号放在 .sdata 之前，gp = 当前 + 0x800。 */
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

    /* .data 的装载地址。只有 .data 从 flash 装载时它才会不同于 _data_start。 */
    _data_load_start = LOADADDR(.data);
    _data_load_end = LOADADDR(.data) + SIZEOF(.data);

    /* 堆从 .bss 结束处向上长。本章不用堆，只留符号给后续章节接管。 */
    _heap_start = _bss_end;

    /* 栈顶在 SRAM 末尾，向下增长；必须 16 字节对齐（ilp32 ABI 要求）。 */
    _stack_top = ORIGIN(sram) + LENGTH(sram);

    /*
     * 掩膜 ROM 里的两个函数，用绝对地址提供：
     *   IDF_PATH/components/esp_rom/esp32s31/ld/esp32s31.rom.ld
     *     ets_printf   = 0x2f800024
     *     ets_delay_us = 0x2f80003c
     * PROVIDE 只在符号仍未定义时生效，因此这一条不会覆盖真正的定义。
     */
    PROVIDE(esp_rom_printf = 0x2f800024);
    PROVIDE(esp_rom_delay_us = 0x2f80003c);
}
