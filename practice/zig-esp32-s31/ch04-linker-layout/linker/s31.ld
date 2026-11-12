/*
 * ch04-linker-layout —— 形态 B 的最小链接脚本（SRAM-only 布局）
 *
 * 这一版做两件事：
 *   1) 在第一个装载段的最前面放 256 字节的 esp_app_desc_t（IDF bootloader 认
 *      镜像的前提，见 src/start.zig 的 app_desc）；
 *   2) 把 .text/.rodata/.data/.bss 全部放进 SRAM，让 ENTRY(_start) +
 *      esptool elf2image + IDF 二级 bootloader 这条链在最小假设下成立。
 *
 * 所有段的 LMA == VMA，所以 _start 不需要搬运 .data；flash 映射
 * （IROM/DROM 窗口 0x40000020）留到下一版布局。
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
    /* RISC-V 的 SRAM 是统一编址：取指与读写共用同一地址空间。 */
    sram (rwx) : ORIGIN = 0x2F000000, LENGTH = 0x7AFC0
}

SECTIONS
{
    /* 代码与只读数据放在一起：将来整体迁到 flash 映射窗口时只改这一段。 */
    .text : ALIGN(16)
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
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(16);
        _text_end = .;
    } > sram

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
