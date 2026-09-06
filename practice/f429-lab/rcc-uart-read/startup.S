/* STM32F429 最小启动：向量表 + 复制 .data + 清 .bss + 进 main。
 * 不依赖任何库；与 ch00e"时钟树"章同源（寄存器级，无 HAL）。 */
.syntax unified
.cpu cortex-m4
.thumb

.global Reset_Handler
.global Default_Handler

.section .isr_vector
.word 0x20030000      /* 初始 SP：SRAM 顶（F429 主 SRAM 192KB 到 0x20030000） */
.word Reset_Handler + 1
.word Default_Handler + 1   /* NMI */
.word Default_Handler + 1   /* HardFault */
.rept 9
.word Default_Handler + 1   /* 其余系统异常占位 */
.endr
/* 外设中断 82 个：全部弱兜底，本工程只用轮询不挂中断 */
.rept 82
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
