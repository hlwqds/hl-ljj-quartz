/*
 * ch09-flash-partition-nvs —— 形态 B 的链接脚本（SRAM-only 布局，与 ch04/ch08 同构）
 *
 * 只做三件事：
 *   1) 在第一个装载段的最前面放 256 字节的 esp_app_desc_t（IDF 二级
 *      bootloader 认镜像的前提，见 src/start.zig 的 app_desc）；
 *   2) 把 .text/.rodata/.data/.bss 全部放进 SRAM，让 ENTRY(_start) +
 *      esptool elf2image + IDF 二级 bootloader 这条链在最小假设下成立；
 *   3) 为 ROM 里的 SPI flash 例程提供绝对地址符号（见文件末尾的 PROVIDE）。
 *
 * 本章为什么坚持“全 SRAM”：写/擦 flash 时 SPI 控制器被 ROM 例程接管，
 * cache 对 flash 的视图会失效。如果代码本身是 XIP 的，写操作期间的取指就
 * 可能踩到失效映射；把代码和数据都放在 SRAM，这个窗口天然安全。代价是
 * 镜像体积受 SRAM（0x7AFC0）限制，本章的几百字节代码远不到这个量级。
 *
 * 本章的 flash 缓冲、分区表副本、KV 记录全部在 .bss：它们必须 4 字节对齐
 * （ROM 的 read/write 以 uint32_t * 访问），由 Zig 侧的类型与 `align(4)` 保证。
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
         * 新的 trap 向量，也不打开中断；flash 的临界窗口只是把 mstatus.MIE
         * 清零，不依赖向量。
         * KEEP 保留它的原因：将来把 flash 操作接成后台任务时，向量仍然要
         * 落在第一个装载段里一个稳定的 4 字节对齐地址上。
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
     * 本章的分区表副本（0xC00 字节）、flash 读缓冲、KV 记录缓冲都在这里。
     * 它们必须在 SRAM 且 4 字节对齐：ROM 的 read/write 以 uint32_t * 访问。
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
     *     ets_printf                  = 0x2f800024
     *     ets_delay_us                = 0x2f80003c
     *     esp_rom_spiflash_erase_sector = 0x2f800160
     *     esp_rom_spiflash_write        = 0x2f800168
     *     esp_rom_spiflash_read         = 0x2f80016c
     * PROVIDE 只在符号仍未定义时生效。
     *
     * 本章的串口输出全部走 esp_rom_printf；ROM 已按 115200 8N1 配好 UART0
     * （GPIO58/59），不需要自己算分频。
     *
     * 三个 flash 函数是绝对地址，与 ROM 版本绑定：换 IDF 版本必须重新核对
     * 这份 rom.ld。签名见 IDF v6.1 的 esp_rom_spiflash.h：
     *   read  (u32 src_address, u32 *dst, u32 len_bytes)
     *   write (u32 target_address, const u32 *src, u32 len_bytes)
     *   erase (u32 sector_number)
     */
    PROVIDE(esp_rom_printf = 0x2f800024);
    PROVIDE(esp_rom_delay_us = 0x2f80003c);
    PROVIDE(esp_rom_spiflash_erase_sector = 0x2f800160);
    PROVIDE(esp_rom_spiflash_write = 0x2f800168);
    PROVIDE(esp_rom_spiflash_read = 0x2f80016c);
}
