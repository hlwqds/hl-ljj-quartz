/* arch/cc.h —— lwIP 移植层之一：平台抽象（小端 + PACK_STRUCT + 诊断出口）
 * 约 30 行，章节原话「cc.h（小端字节序+PACK_STRUCT，约 20 行）」。
 * arch.h 第 48 行 `#include "arch/cc.h"` 找到本文件——必须在 -I 路径的 arch/ 下。 */
#ifndef F429_LWIP_ARCH_CC_H
#define F429_LWIP_ARCH_CC_H

#include <stdint.h>

/* ---- 字节序：Cortex-M4 小端（ldrd/strh 到内存都是小端摆放） ---- */
#ifndef LITTLE_ENDIAN
#define LITTLE_ENDIAN 1234
#endif
#ifndef BIG_ENDIAN
#define BIG_ENDIAN 4321
#endif
#ifndef BYTE_ORDER
#define BYTE_ORDER LITTLE_ENDIAN
#endif

/* ---- 协议头结构体必须逐字节对齐：__attribute__((packed)) ---- */
#define PACK_STRUCT_BEGIN
#define PACK_STRUCT_END
#define PACK_STRUCT_STRUCT __attribute__((packed))
#define PACK_STRUCT_FIELD(x) x

/* ---- sys_prot_t 落户 cc.h ----
 * NO_SYS=1 时 lwIP 不会自动包含 arch/sys_arch.h（它在 sys.h 的 OS 分支里），
 * 但 SYS_LIGHTWEIGHT_PROT 默认=1，sys.h:507 要用 sys_prot_t——而本文件经
 * err.h→arch.h 在任何编译单元里都先于 sys.h 那几行被包含，正是文档认可的安家处。
 * 实现在 port/support.c：PRIMASK 存/关/恢复（单核关中断式临界区）。 */
typedef uint32_t sys_prot_t;

/* ---- 诊断出口：LWIP_PLATFORM_DIAG(x) 里 x 是「带括号的实参表」 ---- */
extern int uart_printf(const char *fmt, ...);
#define LWIP_PLATFORM_DIAG(x) do { uart_printf x; } while (0)

/* ---- 断言：打印位置后原地挂起，等 gdb attach（openocd halt） ---- */
#define LWIP_PLATFORM_ASSERT(x)                                              \
    do {                                                                     \
        uart_printf("\r\n[LWIP ASSERT] %s:%d: %s\r\n", __FILE__, __LINE__,   \
                    (x) ? (const char *)(x) : "?");                          \
        for (;;) {}                                                          \
    } while (0)

#endif
