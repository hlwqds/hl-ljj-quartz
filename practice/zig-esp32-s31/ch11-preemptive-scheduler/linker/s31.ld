/*
 * ch11-preemptive-scheduler —— 形态 B 的链接脚本（SRAM-only 布局，与
 * ch04/ch06/ch08/ch09/ch10 同构）
 *
 * 只做三件事：
 *   1) 在第一个装载段的最前面放 256 字节的 esp_app_desc_t（IDF 二级
 *      bootloader 认镜像的前提，见 src/start.zig 的 app_desc）；
 *   2) 把 trap 入口（.text.trap）放在 4 字节对齐的位置，供 `csrw mtvec` 使用；
 *   3) 把 .text/.rodata/.data/.bss 全部放进 SRAM，让 ENTRY(_start) +
 *      esptool elf2image + IDF 二级 bootloader 这条链在最小假设下成立。
 *
 * 本章不新增段：
 *   - 每个任务的栈是 .bss 里 `align(16)` 的普通数组，链接器按对齐放置；
 *   - TCB 池、8 条就绪队列的头尾指针、tick 的静态变量都是 .bss/.data；
 *   - trap 帧与 switch 帧是栈上的临时布局，不占静态空间。
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
         * trap 入口。mtvec 的低 2 位是模式位，BASE 必须 4 字节对齐；
         * 显式 ALIGN(4) 比依赖“函数符号恰好对齐”可靠。
         * 放在 .app_desc 之后、普通 .text 之前，让它的地址在任何优化级别下稳定。
         */
        . = ALIGN(4);
        KEEP(*(.text.trap))
        . = ALIGN(4);

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
     * 本章的任务栈、TCB 池、就绪队列、tick 的 next_target 都在这里；
     * 栈数组的 align(16) 由 Zig 侧声明保证，链接器只负责满足对齐。
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

    /* 堆从 .bss 结束处向上长。本章不用堆（TCB 与栈全是静态对象）。 */
    _heap_start = _bss_end;

    /*
     * 主栈（也是 idle 任务的栈）在 SRAM 末尾，向下增长；
     * 必须 16 字节对齐（psABI 要求）。
     */
    _stack_top = ORIGIN(sram) + LENGTH(sram);

    /*
     * 掩膜 ROM 里的函数，用绝对地址提供：
     *   IDF_PATH/components/esp_rom/esp32s31/ld/esp32s31.rom.ld
     *     ets_printf   = 0x2f800024
     *     ets_delay_us = 0x2f80003c
     * PROVIDE 只在符号仍未定义时生效。
     *
     * 串口输出全部走 esp_rom_printf；ROM 已按 115200 8N1 配好 UART0
     * （GPIO58/59），tick 不改变串口配置。
     */
    PROVIDE(esp_rom_printf = 0x2f800024);
    PROVIDE(esp_rom_delay_us = 0x2f80003c);
}
