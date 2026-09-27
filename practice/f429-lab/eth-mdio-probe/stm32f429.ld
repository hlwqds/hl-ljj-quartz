/* stm32f429.ld —— F429IG：2MB flash @0x08000000，主 SRAM 192KB @0x20000000
 * 与 rcc-uart-read 同款。注意 .bss 落 0x2000xxxx 普通段：ETH DMA 描述符与
 * 帧缓冲必须 DMA 可达，绝不能落 CCM（0x10000000，DMA 走不进，ch13 铁律）。 */
ENTRY(Reset_Handler)
MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 2048K
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 192K
}
SECTIONS
{
    .isr_vector : { KEEP(*(.isr_vector)) } > FLASH
    .text :
    {
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
        _etext = .;
    } > FLASH
    _sidata = LOADADDR(.data);
    .data :
    {
        . = ALIGN(4);
        _sdata = .;
        *(.data*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT > FLASH
    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        _sbss = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM
    _estack = ORIGIN(RAM) + LENGTH(RAM);
}
