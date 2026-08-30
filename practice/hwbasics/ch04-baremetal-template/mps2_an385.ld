/*
 * mps2_an385.ld -- 最小 Cortex-M3 链接脚本
 *
 * 内存映射依据（QEMU v10.1 源码 hw/arm/mps2.c，FPGA_AN385 分支）：
 *   0x00000000 .. 0x003FFFFF  ZBT SSRAM1（4MB，代码映像加载区，角色=FLASH）
 *   0x20000000 .. 0x203FFFFF  ZBT SSRAM2&3（4MB，数据 RAM）
 * 尺寸取 512K/128K：既在 mps2-an385 范围内，也与 STM32F407VET6 的
 * 主 FLASH(512KB)/SRAM1+2(128KB) 一致，模板可平移到真机。
 */

ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 512K
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 128K
}

/* 栈顶 = RAM 顶端，向下生长；MSP 初值即 _estack（startup.S 向量表槽 0） */
_estack = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS
{
    .text :
    {
        KEEP(*(.isr_vector))   /* 向量表必须在最前（VTOR 默认 0） */
        *(.text*)              /* 代码                            */
        *(.rodata*)            /* 只读数据（字符串常量等）        */
        . = ALIGN(4);
        _etext = .;            /* 代码段结束                       */
    } > FLASH

    /* .data：VMA 在 RAM（运行时地址），LMA 在 FLASH（初始值存放处）。  */
    /* _sidata = LMA：Reset_Handler 拷贝循环的源指针。                   */
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
