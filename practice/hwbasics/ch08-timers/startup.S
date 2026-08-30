/*
 * startup.S -- Cortex-M3 启动文件（ch08-timers，基于 ch04 模板）
 *
 * 相对 ch04 模板的唯一改动：向量表的外部中断区为 CMSDK 定时器让出
 * 具名槽位（覆盖 Default_Handler 弱符号），其余与模板逐行一致。
 *
 *   IRQ8  = CMSDK APB Timer0    0x40000000（本章未用，留槽）
 *   IRQ9  = CMSDK APB Timer1    0x40001000（本章未用，留槽）
 *   IRQ10 = CMSDK APB DualTimer 0x40002000（本章实验二：1Hz 中断）
 *
 * 依据：QEMU v10.1.5 hw/arm/mps2.c（base = 0x40000000 + i*0x1000,
 * irqno = 8 + i；dualtimer 固定 0x40002000 / IRQ 10）
 */

.syntax unified
.cpu cortex-m3
.thumb

/* ------------------------------------------------------------------ */
/* 1. 向量表：必须位于映像偏移 0（VTOR 复位默认值 = 0）                  */
/* ------------------------------------------------------------------ */
.section .isr_vector, "a", %progbits
.align 2
.global _vectors
_vectors:
    .word _estack             /* 0: 初始 MSP，硬件上电自动加载            */
    .word Reset_Handler       /* 1: 复位向量，硬件上电自动加载为 PC        */
    .word NMI_Handler         /* 2: NMI                                   */
    .word HardFault_Handler   /* 3: HardFault                             */
    .word Default_Handler     /* 4: MemManage（M3 无 MMU，仅保留槽位）     */
    .word Default_Handler     /* 5: BusFault                              */
    .word Default_Handler     /* 6: UsageFault                            */
    .word 0                   /* 7: reserved                              */
    .word 0                   /* 8: reserved                              */
    .word 0                   /* 9: reserved                              */
    .word 0                   /* 10: reserved                             */
    .word SVC_Handler         /* 11: SVCall                               */
    .word Default_Handler     /* 12: DebugMonitor                         */
    .word 0                   /* 13: reserved                             */
    .word PendSV_Handler      /* 14: PendSV（FreeRTOS 上下文切换入口）     */
    .word SysTick_Handler     /* 15: SysTick（实验一/二的时间基 A）        */

    /* 外部中断 IRQ0..IRQ7：默认兜底 */
    .rept 8
    .word Default_Handler
    .endr
    .word CMSDK_TIMER0_IRQHandler    /* IRQ8 : CMSDK APB Timer0           */
    .word CMSDK_TIMER1_IRQHandler    /* IRQ9 : CMSDK APB Timer1           */
    .word CMSDK_DUALTIMER_IRQHandler /* IRQ10: CMSDK APB DualTimer(合并)  */
    /* IRQ11..IRQ31：默认兜底 */
    .rept 21
    .word Default_Handler
    .endr

/* ------------------------------------------------------------------ */
/* 2. Reset_Handler：拷 .data、清 .bss、进 C 世界（与 ch04 模板一致）    */
/* ------------------------------------------------------------------ */
.section .text
.global Reset_Handler
.type Reset_Handler, %function
.thumb_func
Reset_Handler:
    ldr  r0, =_sidata
    ldr  r1, =_sdata
    ldr  r2, =_edata
1:
    cmp  r1, r2
    bhs  2f
    ldr  r3, [r0], #4
    str  r3, [r1], #4
    b    1b
2:
    movs r3, #0
    ldr  r1, =_sbss
    ldr  r2, =_ebss
3:
    cmp  r1, r2
    bhs  4f
    str  r3, [r1], #4
    b    3b
4:
    bl   main
5:
    b    5b

.size Reset_Handler, . - Reset_Handler

/* ------------------------------------------------------------------ */
/* 3. 默认异常处理 + 弱符号表                                            */
/* ------------------------------------------------------------------ */
.section .text
.global Default_Handler
.type Default_Handler, %function
.thumb_func
Default_Handler:
    b    .
.size Default_Handler, . - Default_Handler

.weak NMI_Handler
.thumb_set NMI_Handler, Default_Handler
.weak HardFault_Handler
.thumb_set HardFault_Handler, Default_Handler
.weak SVC_Handler
.thumb_set SVC_Handler, Default_Handler
.weak PendSV_Handler
.thumb_set PendSV_Handler, Default_Handler
.weak SysTick_Handler
.thumb_set SysTick_Handler, Default_Handler
.weak CMSDK_TIMER0_IRQHandler
.thumb_set CMSDK_TIMER0_IRQHandler, Default_Handler
.weak CMSDK_TIMER1_IRQHandler
.thumb_set CMSDK_TIMER1_IRQHandler, Default_Handler
.weak CMSDK_DUALTIMER_IRQHandler
.thumb_set CMSDK_DUALTIMER_IRQHandler, Default_Handler
