/*
 * startup.S -- Cortex-M3 启动文件（ch07 中断版，底座 = ch04 模板）
 *
 * 与 ch04 的差异只有一处：向量表的外部中断槽从 `.rept 32 Default_Handler`
 * 展开成"带注释的具名槽位"。IRQ 号考证自 QEMU v10.1.5 hw/arm/mps2.c
 * （FPGA_AN385 分支：uartirq[] = {0,2,4,18,20}，RX 在前 TX 恒为 RX+1；
 * 定时器 irqno = 8+i；dualtimer=10；UART0-2 溢出 6 线 OR 后接 NVIC 12）。
 *
 * 未实现的槽位仍指 Default_Handler（弱符号，应用代码用同名强符号覆盖）。
 *
 * 对应章节：《嵌入式硬件基础（七）：中断体系——NVIC、EXTI 与中断驱动的 UART》
 */

.syntax unified
.cpu cortex-m3
.thumb

/* ------------------------------------------------------------------ */
/* 1. 向量表：必须位于映像偏移 0（VTOR 复位默认值 = 0）                 */
/* ------------------------------------------------------------------ */
.section .isr_vector, "a", %progbits
.align 2
.global _vectors
_vectors:
    .word _estack             /* 0:  初始 MSP，硬件上电自动加载           */
    .word Reset_Handler       /* 1:  复位向量，硬件上电自动加载为 PC      */
    .word NMI_Handler         /* 2:  NMI                                   */
    .word HardFault_Handler   /* 3:  HardFault                             */
    .word Default_Handler     /* 4:  MemManage（M3 无 MMU，仅保留槽位）    */
    .word Default_Handler     /* 5:  BusFault                              */
    .word Default_Handler     /* 6:  UsageFault                           */
    .word 0                   /* 7:  reserved                             */
    .word 0                   /* 8:  reserved                             */
    .word 0                   /* 9:  reserved                             */
    .word 0                   /* 10: reserved                             */
    .word SVC_Handler         /* 11: SVCall                              */
    .word Default_Handler     /* 12: DebugMonitor                        */
    .word 0                   /* 13: reserved                            */
    .word PendSV_Handler      /* 14: PendSV（FreeRTOS 上下文切换入口）    */
    .word SysTick_Handler     /* 15: SysTick（本章实验一）                */

    /* ---- 外部中断 IRQ0..IRQ31：槽 n 的向量表偏移 = (16+n)*4 ------------- */
    /* ---- 异常号 = 16+n；NVIC 寄存器里的位号 = n                          */
    .word UART0_RX_Handler    /* IRQ 0 : UART0 RX  ← 本章实验二           */
    .word UART0_TX_Handler    /* IRQ 1 : UART0 TX                         */
    .word Default_Handler     /* IRQ 2 : UART1 RX                         */
    .word Default_Handler     /* IRQ 3 : UART1 TX                         */
    .word Default_Handler     /* IRQ 4 : UART2 RX                         */
    .word Default_Handler     /* IRQ 5 : UART2 TX                         */
    .word Default_Handler     /* IRQ 6 : （保留）                          */
    .word Default_Handler     /* IRQ 7 : （保留）                          */
    .word Default_Handler     /* IRQ 8 : Timer0（ch08 使用）               */
    .word Default_Handler     /* IRQ 9 : Timer1（ch08 使用）               */
    .word Default_Handler     /* IRQ 10: DualTimer（ch08 使用）            */
    .word Default_Handler     /* IRQ 11: SPI0+LCD（OR 后）                 */
    .word Default_Handler     /* IRQ 12: UART0-2 溢出（OR 后）             */
    .word Default_Handler     /* IRQ 13: LAN9118 以太网                    */
    .word Default_Handler     /* IRQ 14: （保留）                          */
    .word Default_Handler     /* IRQ 15: （保留）                          */
    .word Default_Handler     /* IRQ 16: （保留）                          */
    .word Default_Handler     /* IRQ 17: （保留）                          */
    .word Default_Handler     /* IRQ 18: UART3 RX                         */
    .word Default_Handler     /* IRQ 19: UART3 TX                         */
    .word Default_Handler     /* IRQ 20: UART4 RX                         */
    .word Default_Handler     /* IRQ 21: UART4 TX                         */
    .word Default_Handler     /* IRQ 22: PL022 外部 ADC                    */
    .word Default_Handler     /* IRQ 23: （保留）                          */
    .word Default_Handler     /* IRQ 24: SPI Shield0+1（OR 后）            */
    .rept 7                   /* IRQ 25..31 剩余槽位                       */
    .word Default_Handler
    .endr

/* ------------------------------------------------------------------ */
/* 2. Reset_Handler：上电后执行的第一段软件                             */
/* ------------------------------------------------------------------ */
.section .text
.global Reset_Handler
.type Reset_Handler, %function
.thumb_func
Reset_Handler:
    /* 2a. 拷贝 .data：FLASH 中的初始值(_sidata) -> RAM(_sdata.._edata) */
    ldr  r0, =_sidata         /* r0 = 源（LMA，位于 FLASH）               */
    ldr  r1, =_sdata          /* r1 = 目标起点（VMA，位于 RAM）           */
    ldr  r2, =_edata          /* r2 = 目标终点                            */
1:
    cmp  r1, r2
    bhs  2f                   /* 目标追上终点，拷贝结束                   */
    ldr  r3, [r0], #4         /* r3 = *src++;                             */
    str  r3, [r1], #4         /* *dst++ = r3;                             */
    b    1b

    /* 2b. 清零 .bss：C 标准要求全局变量进入 main 前为 0                 */
2:
    movs r3, #0
    ldr  r1, =_sbss
    ldr  r2, =_ebss
3:
    cmp  r1, r2
    bhs  4f
    str  r3, [r1], #4         /* *dst++ = 0;                              */
    b    3b

    /* 2c. 进入 C 世界                                                     */
4:
    bl   main                 /* 永不返回（main 末尾死循环）              */
5:
    b    5b                   /* 防御：万一返回了就挂在此处               */

.size Reset_Handler, . - Reset_Handler

/* ------------------------------------------------------------------ */
/* 3. 默认异常处理：未显式实现的异常最终都落到这里（死循环）              */
/* ------------------------------------------------------------------ */
.section .text
.global Default_Handler
.type Default_Handler, %function
.thumb_func
Default_Handler:
    b    .
.size Default_Handler, . - Default_Handler

/* 弱符号：应用代码可用同名强符号覆盖任意处理函数                        */
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
.weak UART0_RX_Handler
.thumb_set UART0_RX_Handler, Default_Handler
.weak UART0_TX_Handler
.thumb_set UART0_TX_Handler, Default_Handler
