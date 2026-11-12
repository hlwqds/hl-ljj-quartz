/*
 * ch08-timers-dma —— 形态 B 的链接脚本（SRAM-only 布局，与 ch04/ch06 同构）
 *
 * 只做两件事：
 *   1) 在第一个装载段的最前面放 256 字节的 esp_app_desc_t（IDF 二级
 *      bootloader 认镜像的前提，见 src/start.zig 的 app_desc）；
 *   2) 把 .text/.rodata/.data/.bss 全部放进 SRAM，让 ENTRY(_start) +
 *      esptool elf2image + IDF 二级 bootloader 这条链在最小假设下成立。
 *
 * 本章的定时器与 DMA 都不需要新的段：
 *   - TIMG/SYSTIMER 是纯 MMIO，代码里只有 volatile 读写；
 *   - DMA 描述符是 12 字节、4 字节对齐的普通结构体，落在 .bss 里，
 *     `align(4)` 由 Zig 侧保证，这里不需要特殊放置。
 *
 * 所有段的 LMA == VMA，所以 _start 不需要搬运 .data。
 *
 * 地址来源：ESP-IDF v6.1 的 esp32s31 内存定义
 *   IDF_PATH/components/esp_system/ld/esp32s31/memory.ld.in
 * 其中 SRAM 段为 0x2F000000 .. 0x2F07AFC0，长度 0x7AFC0。
 * 本文件只抄录这个区间；段布局是本工程自己写的，不复制 IDF 的链接脚本。
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
        /*
         * 第一个装载段必须以 esp_app_desc_t 开头：256 字节、魔数 0xABCD5432。
         * 大小由 src/start.zig 的 comptime 断言保证。
         */
        _image_start = .;
        KEEP(*(.app_desc))
        . = ALIGN(16);

        _text_start = .;

        /*
         * ch06 把 trap 向量（异常用，mtvec MODE=0）放在这里。本章不安装
         * 新的 trap 向量，也不打开中断，但 `_start` 依然把 mie/mstatus.MIE
         * 清零——定时器与 DMA 全部用轮询完成，所以这个段可以留空。
         * KEEP 保留它的原因：将来把 TIMG 闹钟接成中断时，向量仍然要落在
         * 第一个装载段里一个稳定的 4 字节对齐地址上。
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
        /* RISC-V small-data anchor：gp = 当前 + 0x800，与 IDF 的 ld 片段同款。 */
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        . = ALIGN(16);
        _data_end = .;
    } > sram

    /*
     * 零初始化数据：NOBITS，镜像里只有地址与长度，内容由 _start 清零。
     * 本章的 DMA 描述符数组与收发缓冲都在这里；它们必须位于 SRAM
     * （AHB GDMA 可以访问 PSRAM，但本节目的验证先用 SRAM 把链路跑通）。
     */
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
     * 掩膜 ROM 里的函数，用绝对地址提供：
     *   IDF_PATH/components/esp_rom/esp32s31/ld/esp32s31.rom.ld
     *     ets_printf   = 0x2f800024
     *     ets_delay_us = 0x2f80003c
     * PROVIDE 只在符号仍未定义时生效。
     *
     * 本章的串口输出全部走 esp_rom_printf；ROM 已按 115200 8N1 配好 UART0
     * （GPIO58/59），不需要自己算分频。
     */
    PROVIDE(esp_rom_printf = 0x2f800024);
    PROVIDE(esp_rom_delay_us = 0x2f80003c);
}
