/*
 * startup.S -- Cortex-M 最小启动文件（QEMU mps2-an385 / STM32F407 通用）
 *
 * 与 ch04-baremetal-template/startup.S 唯一差异：
 *   去掉了文件内固定的 `.cpu cortex-m3`，改由命令行 -mcpu 传入——
 *   这样同一份启动文件可以同时服务两个目标：
 *     QEMU 目标：-mcpu=cortex-m3（mps2-an385）
 *     F407 目标：-mcpu=cortex-m4（编译验证用，QEMU 无 F407 机型）
 *   两套指令集（ARMv7-M / ARMv7E-M）对本文件用到的指令完全兼容。
 *
 * 职责（与 ch04 相同）：
 *   1. 向量表（.isr_vector）位于映像偏移 0（VTOR 复位默认值 = 0）
 *   2. Reset_Handler：.data 拷贝 + .bss 清零 + bl main
 *   3. Default_Handler 弱符号兜底
 *
 * 对应章节：《嵌入式硬件基础（五）：GPIO 与时钟树》
 */

.syntax unified
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
    .word SysTick_Handler     /* 15: SysTick（ch07/ch08 实验使用）         */

    /* 外部中断 IRQ0..IRQ31（mps2-an385 的 NVIC 有 32 条 IRQ 线；       */
    /* 未用到的槽位统一指向 Default_Handler，后续章节按需替换）          */
    .rept 32
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
