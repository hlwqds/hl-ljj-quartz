/* ch03 实验最小启动文件：验证向量表与异常栈帧。
 * 只为 QEMU -M mps2-an385 (Cortex-M3) 服务，不初始化任何 C 环境。
 * ch04 会把它扩展成完整启动文件，本章先当黑盒工具用。
 */
.cpu cortex-m3
.thumb
.syntax unified

/* ---------- 向量表：必须是映像的第一个节 ---------- */
.section .isr_vector, "a", %progbits
.word _estack           /*  0: 初始 MSP（不是跳转目标！）        */
.word Reset_Handler     /*  1: Reset                            */
.word Default_Handler   /*  2: NMI                              */
.word Default_Handler   /*  3: HardFault                        */
.word Default_Handler   /*  4: MemManage                        */
.word Default_Handler   /*  5: BusFault                         */
.word Default_Handler   /*  6: UsageFault                       */
.word 0                 /*  7: Reserved                         */
.word 0                 /*  8: Reserved                         */
.word 0                 /*  9: Reserved                         */
.word 0                 /* 10: Reserved                         */
.word SVC_Handler       /* 11: SVCall                           */
.word Default_Handler   /* 12: DebugMonitor                     */
.word 0                 /* 13: Reserved                         */
.word Default_Handler   /* 14: PendSV                           */
.word Default_Handler   /* 15: SysTick                          */

/* ---------- 代码 ---------- */
.section .text
.thumb_func
.global Reset_Handler
Reset_Handler:
    /* 给 R0-R3/R12/LR 塞魔数，SVC 触发异常入栈后
     * 这些值会原样出现在 MSP 栈帧里，用来核对压栈顺序。 */
    ldr     r0,  =0xAAAA0001
    ldr     r1,  =0xAAAA0002
    ldr     r2,  =0xAAAA0003
    ldr     r3,  =0xAAAA0004
    ldr     r12, =0xAAAA000C
    ldr     lr,  =0x00ED0001      /* 伪造"调用者返回地址" */
    svc     #0                     /* 触发 SVCall（异常号 11） */

after_svc:                        /* 异常返回后落到这里，
                                     栈帧里的 PC 应指向本行 */
    b       after_svc              /* 停在这，gdb 验证 MSP 已复原 */

.thumb_func
.global SVC_Handler
SVC_Handler:
    /* LR = EXC_RETURN（返回 Thread/MSP = 0xFFFFFFF9）；
     * $sp 指向硬件压好的 8 字栈帧。这里什么都不做直接返回，
     * 让 gdb 在 after_svc 处验证出栈：MSP 复原、R0-R3 魔数回寄存器。 */
    bx      lr

.thumb_func
Default_Handler:
    b       Default_Handler
