/*
 * ch07-interrupts-clic —— 形态 B 的链接脚本（SRAM-only 布局，与 ch04/ch06 同构）
 *
 * 这一版仍然只做两件事：
 *   1) 在第一个装载段的最前面放 256 字节的 esp_app_desc_t（IDF 二级
 *      bootloader 认镜像的前提，见 src/start.zig 的 app_desc）；
 *   2) 把 .text/.rodata/.data/.bss 全部放进 SRAM，让 ENTRY(_start) +
 *      esptool elf2image + IDF 二级 bootloader 这条链在最小假设下成立。
 *
 * 与 ch06 的差别只有一处：`.text.entry` 里现在放的是 `isr.zig` 的
 * `trapVector`——它同时承接**异常与中断**（mtvec MODE=0）。要求没变，
 * 但分量变重了：
 *
 *   - 4 字节对齐是硬要求（mtvec.BASE 的低 2 位是模式位）。`ALIGN(16)` 之后
 *     紧跟 `KEEP(*(.text.entry))`，所以它的地址天然是 16 的倍数。
 *   - 本章**不**使用 CLIC 的向量模式（mtvec MODE=3 + mtvt）：那条路要求
 *     一张 64 字节对齐、每项 4 字节 `j handler` 的表，还要把表放在 ±1 MB
 *     可达范围内。ch04–ch06 的布局没有为它留位置，本章也不声称它已验证。
 *     真要用时，在这里加一个 `. = ALIGN(64); KEEP(*(.trapvec))` 的段更省事，
 *     但必须先上板确认 mtvt 的对齐与条目语义（见章节 7.3 的「待真机验证」）。
 *
 * 所有段的 LMA == VMA，所以 _start 不需要搬运 .data；flash 映射
 * （IROM/DROM 窗口 0x40000020）留到后续版本。
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
    /* 代码与只读数据放在一起：将来整体迁到 flash 映射窗口时只改这一段。 */
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

        /*
         * 必须最先放置的入口段：本章放 trap 向量（src/isr.zig 的 trapVector）。
         * KEEP 防止 --gc-sections 把它丢掉；ALIGN 之后的第一项因此位于
         * _text_start（本章仍是 0x2F000100 一带），16 字节对齐满足 mtvec
         * 的 4 字节对齐要求。它在 `mtvec` 装上之前不会被用到。
         */
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

    /* trap 向量/中断入口必须放 SRAM：真机发现（2026-11-12）向量放 flash 时，
     * 异常/中断投递直接 CPU_LOCKUP_RESET（rst:0x1a），连 mtvec 里的死循环
     * 都执行不到（ch06 复现）。IDF 同样把异常入口放 IRAM。 */
    .trap_ram : ALIGN(4)
    {
        KEEP(*(.trap_ram))
        . = ALIGN(4);
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
     *
     * 本章的 UART TX 仍然全部走 esp_rom_printf（含 trap 报告）：
     * 中断路径里只写环形缓冲，不打印。
     */
    PROVIDE(esp_rom_printf = 0x2f800024);
    PROVIDE(esp_rom_delay_us = 0x2f80003c);
}
