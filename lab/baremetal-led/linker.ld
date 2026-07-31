/*
 * linker.ld — 裸机 LED 程序链接脚本
 *
 * 程序加载到 vexpress-a9 RAM 起始地址 0x60000000。
 * qemu -kernel 会把 bin 加载到这个地址并从入口执行。
 */

ENTRY(_start)

SECTIONS
{
    /* 程序起始地址 = RAM 起始 */
    . = 0x60000000;

    .text : {
        start.o (.text.start)   /* 汇编入口在前 */
        *(.text)
    }

    .rodata : { *(.rodata) }
    .data : { *(.data) }

    .bss : {
        __bss_start = .;
        *(.bss)
        *(COMMON)
        __bss_end = .;
    }
}
