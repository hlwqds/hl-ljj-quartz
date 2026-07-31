/*
 * start.S — 裸机程序汇编入口
 *
 * qemu -kernel 加载后从 0x60000000 开始执行（vexpress-a9 RAM 起始）。
 * 这里设置栈指针，然后跳转到 C 的 main()。
 */

    .section .text.start
    .global _start

_start:
    /* 设置栈指针（栈向下生长，RAM 顶部 0x80000000） */
    ldr sp, =0x80000000

    /* 跳转到 C main */
    bl  main

    /* main 返回后死循环 */
hang:
    b   hang
