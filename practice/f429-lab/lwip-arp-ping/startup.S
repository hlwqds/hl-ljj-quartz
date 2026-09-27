/* eth_mdio_probe 启动：向量表 + 复制 .data + 清 .bss + 进 main。
 * 与 rcc-uart-read 同源，但修正向量表：Cortex-M4 内核异常共 16 个
 * （rcc-uart-read 只摆了 13 个——它不开中断所以没炸；本工程用 SysTick，
 * 向量槽必须对齐）。F429 外部中断 91 个（IRQ0..90，ETH=61），全弱兜底，
 * 本工程纯轮询，唯一强符号是 SysTick_Handler（g_ms 心跳，ch01 地基）。 */
.syntax unified
.cpu cortex-m4
.thumb

.global Reset_Handler
.global Default_Handler

.section .isr_vector
.word 0x20030000      /* 初始 SP：SRAM 顶（F429 主 SRAM 192KB 到 0x20030000） */
.word Reset_Handler + 1
.word Default_Handler + 1   /*  0 NMI */
.word Default_Handler + 1   /*  1 HardFault */
.rept 8
.word Default_Handler + 1   /*  2..9  MemManage/BusFault/UsageFault/保留x4 */
.endr
.word Default_Handler + 1   /* 10 SVCall */
.word Default_Handler + 1   /* 11 DebugMon */
.word Default_Handler + 1   /* 12 保留 */
.word Default_Handler + 1   /* 13 PendSV */
.word SysTick_Handler + 1   /* 14 SysTick——本工程的心跳入口 */
/* 外部中断 91 个（IRQ0..90）：全部兜底，本工程不挂任何中断（纯轮询） */
.rept 91
.word Default_Handler + 1
.endr

.section .text
.thumb_func
Reset_Handler:
    ldr  r0, =_sidata      /* .data 的 LMA（flash 中） */
    ldr  r1, =_sdata       /* VMA（SRAM） */
    ldr  r2, =_edata
1:  cmp  r1, r2
    bcs  2f
    ldr  r3, [r0], #4
    str  r3, [r1], #4
    b    1b
2:  ldr  r1, =_sbss
    ldr  r2, =_ebss
    movs r3, #0
3:  cmp  r1, r2
    bcs  4f
    str  r3, [r1], #4
    b    3b
4:  bl   main
5:  b    5b

.thumb_func
Default_Handler:
    b    Default_Handler
