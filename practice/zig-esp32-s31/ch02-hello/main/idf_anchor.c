/*
 * ch02 的最小 C 锚点。
 *
 * 两个作用：
 *   1. 让 IDF 的 main 组件至少拥有一个 C 源文件，从而生成组件静态库；
 *   2. 给后续章节留一个稳定的 C/Zig 交界位置（中断入口、链接脚本符号、
 *      IDF 头文件封装都可以先落在这里）。
 *
 * 注意：这里不定义 app_main。app_main 在 main.zig 中导出，由 Zig 静态库
 * libmain_zig.a 提供；本文件只保证组件存在，不参与启动流程。
 */

void zig_s31_anchor(void);

void zig_s31_anchor(void)
{
}
