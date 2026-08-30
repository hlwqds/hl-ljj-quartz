/* ch03 最小链接脚本：向量表钉在 0x0，栈顶取 RAM 末尾。
 * mps2-an385: 0x00000000 4MB SRAM（当作 Flash 用），0x20000000 4MB SRAM。
 */
ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 4M
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 4M
}

/* 初始 MSP = RAM 末尾（满减栈，向低地址生长） */
_estack = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS
{
    .isr_vector :
    {
        KEEP(*(.isr_vector))
    } > FLASH

    .text :
    {
        *(.text*)
        *(.rodata*)
    } > FLASH

    /DISCARD/ : { *(.comment) *(.ARM.attributes) }
}
