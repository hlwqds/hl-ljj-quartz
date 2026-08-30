/*
 * f407.ld -- STM32F407VET6 链接脚本（编译验证目标）
 *
 * 内存映射依据 ST RM0090 §2.3（Memory map）与 STM32F407 数据手册：
 *   主 FLASH  0x08000000 .. 0x0807FFFF（512KB，F407VET6 实际容量）
 *   SRAM1+2  0x20000000 .. 0x2001FFFF（连续 128KB；另有 CCM 64KB @0x10000000，
 *             只能 CPU 访问，裸机阶段先不用）
 *
 * 注意：F407 复位后 VTOR=0x00000000，但 BOOT0=0 时硬件把主 FLASH
 * 别名到 0x00000000，所以向量表放在 0x08000000 处照样能被取到；
 * 稳妥起见正式固件可在 Reset_Handler 里把 SCB->VTOR 设为 0x08000000。
 */

ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 512K
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 128K
}

/* 栈顶 = RAM 顶端，向下生长；MSP 初值即 _estack（startup.S 向量表槽 0） */
_estack = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS
{
    .text :
    {
        KEEP(*(.isr_vector))   /* 向量表必须在最前（BOOT0=0 时别名到 0x0） */
        *(.text*)              /* 代码                            */
        *(.rodata*)            /* 只读数据（字符串常量等）        */
        . = ALIGN(4);
        _etext = .;            /* 代码段结束                       */
    } > FLASH

    /* .data：VMA 在 RAM（运行时地址），LMA 在 FLASH（初始值存放处）。  */
    _sidata = LOADADDR(.data);

    .data :
    {
        . = ALIGN(4);
        _sdata = .;            /* 拷贝目标起点                      */
        *(.data*)
        . = ALIGN(4);
        _edata = .;            /* 拷贝目标终点                      */
    } > RAM AT > FLASH

    /* .bss：无初始值/初值为 0 的变量，不占映像体积，只需清零            */
    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        _sbss = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    /DISCARD/ :
    {
        *(.comment)
        *(.ARM.attributes)
        *(.ARM.exidx*)         /* 裸机无异常展开表，丢弃              */
    }
}

/* 防御性检查：映像超出 FLASH 或静态变量超出 RAM 时链接期即报错          */
ASSERT(_etext <= ORIGIN(FLASH) + LENGTH(FLASH), "FLASH overflow")
ASSERT(_ebss <= _estack, "RAM overflow: data+bss 蚕食了整个栈空间")
