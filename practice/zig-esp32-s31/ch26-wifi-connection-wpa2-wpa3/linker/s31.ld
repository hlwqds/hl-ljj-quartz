/*
 * ch26-wifi-connection-wpa2-wpa3 —— 形态 B 的链接脚本
 *
 * 骨架与 ch13–ch25 相同（SRAM-only 布局 + 两个 flash 装载段），本章不改
 * 任何地址：WPA2/SAE 的字节层与连接状态机都是纯逻辑，板侧只需要一块合法的
 * SRAM 放几个计数器：
 *
 * 本章板侧一共 13 条判据（`check:` 行），全部打印在 ../logs/ch26-boot.log。
 * 它们不需要任何静态工作区——状态机与队列都是判据函数里的局部实例，
 * 校验的就是「每个实例自己从零开始」。
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
 * 一处布局事实：本章的 `.rodata` 只有字符串、常数表与 32/64 字节的测试
 * 向量（全部 8 字节对齐以内），没有 AES S-box 那种 64 字节对齐的查表，
 * 所以 DROM 段起点就是 ORIGIN(drom) = 0x40020020。用 AES 软件查表的章节
 * 会因 S-box 的 64 字节对齐被顶到 0x40020040。
 * 具体落点以 `esptool image-info` 打印的两行为准，见章节 26.10。
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
     * 本章的 `.rodata` 是字符串、SAE 的素数/阶常数表与测试向量，对齐要求
     * ≤ 8 字节，所以输出节落在 ORIGIN(drom) = 0x40020020 上。bootloader
     * 真正检查的不是「段必须落在 ORIGIN 上」，而是页内偏移同余：
     *     esp_image_format.c:904
     *     segment_data_offs % mmu_page_size == load_addr % mmu_page_size
     * elf2image 会插入填充段把 paddr 对齐到同样的偏移，这条检查因此通过。
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

    /* 有初值的可写数据。本布局 LMA == VMA：_start 不需要搬运。
     * 本章没有初值可写数据之外的东西——测试向量是 `const`，落在 .rodata。 */
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
     * 本工程的静态对象很少（实测 .bss = 0x10 = 16 B）：
     *   g_passed / g_failed   两个判据计数器（各 4 B）
     *   其余                   Zig 运行时的一两个指针
     * 状态机、事件队列、EAPOL 帧缓冲全部在 **16 KiB 主栈**上开：
     *   conn.Machine  104 B（内含 EventQueue 80 B = 8 × 8 B Event）
     *   wpa2.KeyFrame  64 B、wpa2.FourWay 80 B、sae.Keys 144 B
     * 栈上放得下，而且判据 ⑫ 要的是「队列满时的行为」，用局部实例更干净：
     * 每个判据自己一份，互不污染。_start 仍然清 .bss——计数器和运行时全局
     * 必须从零开始，否则判据 ① 的 passed 计数会带上上一次运行的值。 */
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
     * 堆从 _bss_end 长到 _stack_bottom。本章不用堆：PBKDF2/PRF/SAE 全部
     * 在栈上的固定缓冲里算，所以 `_heap_start.._heap_end` 只是留给后续
     * 章节的余地。自检会打印结构长度，不打印这四个边界。
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
    ASSERT(_rodata_start % 16 == 0,
        ".flash.rodata must stay 16-byte aligned")
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
