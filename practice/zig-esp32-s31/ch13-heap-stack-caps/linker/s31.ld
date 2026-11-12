/*
 * ch13-heap-stack-caps —— 形态 B 的链接脚本（与 ch11 同一骨架，多出堆/栈边界符号）
 *
 * 与 ch11 的差别只有一处：把 SRAM 末尾划成
 *
 *     [_bss_end ......... _heap_start)   .bss 结束处即堆起点（向上长）
 *     [_heap_start ...... _heap_end)     TLSF arena：本章的所有分配都来自这里
 *     [_stack_bottom .... _stack_top)    主栈 16 KiB，向下增长（_start 装 sp）
 *
 * 三个边界都是符号，不在 C/Zig 里手抄地址：`src/heap.zig` 用 `_heap_start`/
 * `_heap_end` 定义 arena，`src/stack_guard.zig` 用 `_stack_bottom`/`_stack_top`
 * 填充哨兵并算高水位。地址一改，代码不用动。
 *
 * 不变的硬约束（真机实测，见 ../BRINGUP-2026-11-12.md）：
 *   1) bootloader 断言镜像里正好两个 flash 段（IROM + DROM），0x20 偏移；
 *   2) trap 向量必须落在 SRAM（.trap_ram），放 flash 会 CPU_LOCKUP_RESET；
 *   3) 第一个装载段最前面是 256 字节 esp_app_desc_t。
 *
 * 地址来源：ESP-IDF v6.1 的 esp32s31 内存定义
 *   components/esp_system/ld/esp32s31/memory.ld.in    SRAM 0x2F000000，长度 0x7AFC0
 *   components/esp_system/ld/esp32s31/ld.hp_mem_defs  SRAM_SEG_END = 0x2F07AFC0
 * SRAM 物理上是 512 KiB（0x80000），末尾 0x5040 被二级 bootloader 的
 * iram_loader_seg 占着，所以应用可用到 0x2F07AFC0。
 */

ENTRY(_start)

MEMORY
{
    /* bootloader 的 unpack_load_app 要求正好两个落在 0x40000000..0x44000000
     * 的段（IROM + DROM）；只有 SRAM 段的镜像会断言失败。 */
    irom (rx)  : ORIGIN = 0x40000020, LENGTH = 0x3F000
    drom (r)   : ORIGIN = 0x40020020, LENGTH = 0x3F000
    sram (rwx) : ORIGIN = 0x2F000000, LENGTH = 0x7AFC0
}

SECTIONS
{
    .flash.text : ALIGN(16)
    {
        /* 第一个装载段必须以 esp_app_desc_t 开头（魔数 0xABCD5432，256 字节）。 */
        _image_start = .;
        KEEP(*(.app_desc))
        . = ALIGN(16);

        _text_start = .;

        /* mtvec.BASE 必须 4 字节对齐，显式 ALIGN(4) 比依赖函数符号对齐可靠。 */
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

    /* trap 向量必须放 SRAM：放 flash 时异常/中断投递直接 CPU_LOCKUP_RESET。 */
    .trap_ram : ALIGN(4)
    {
        _trap_start = .;
        KEEP(*(.trap_ram))
        . = ALIGN(4);
        _trap_end = .;
    } > sram

    /* 有初值的可写数据。本章 LMA == VMA，_start 不搬运 .data。 */
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

    /*
     * 零初始化数据：NOBITS，内容由 _start 清零。
     * 本章的 TLSF 位图/空闲链头、slab 类描述、模拟任务栈数组都在这里。
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

    _data_load_start = LOADADDR(.data);
    _data_load_end = LOADADDR(.data) + SIZEOF(.data);

    /* ---------------------------------------------------------------------
     * 堆与栈的边界
     *
     * 主栈 16 KiB 放在 SRAM 最末尾（_start 里 `la sp, _stack_top`）。
     * 堆从 _bss_end 长到 _stack_bottom。两者之间的空隙就是 arena 的全部预算。
     * ------------------------------------------------------------------- */
    _stack_size = 0x4000;
    _stack_top = ORIGIN(sram) + LENGTH(sram);
    _stack_bottom = _stack_top - _stack_size;

    _heap_start = _bss_end;
    _heap_end = _stack_bottom;

    /* 静态对象吃进栈区就直接构建失败，而不是运行期把栈踩掉。 */
    ASSERT(_bss_end <= _stack_bottom, "SRAM exhausted: .bss overlaps the 16 KiB main stack")

    /*
     * 掩膜 ROM 函数：IDF v6.1 components/esp_rom/esp32s31/ld/esp32s31.rom.ld
     *   ets_printf   = 0x2f800024
     *   ets_delay_us = 0x2f80003c
     * ROM 区间 0x2F800000..0x2F850000（soc.h: SOC_IROM_MASK_LOW/HIGH），
     * 已经越过了应用可用的 SRAM 顶端 0x2F07AFC0，是另一块地址空间。
     */
    PROVIDE(esp_rom_printf = 0x2f800024);
    PROVIDE(esp_rom_delay_us = 0x2f80003c);
}
