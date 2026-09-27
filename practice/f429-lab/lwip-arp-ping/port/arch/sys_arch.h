/* arch/sys_arch.h —— lwIP 移植层之二：OS 抽象（NO_SYS=1 极简版）
 * lwip/sys.h 第 95 行 `#include "arch/sys_arch.h"`——注意它在此前只包含了
 * opt.h/err.h，类型要自给自足（<stdint.h>），不能假设 u32_t 已定义。
 * 升级 NO_SYS=0 + FreeRTOS 时，这里变成 sys_arch.c 的类型映射表
 * （信号量/互斥/邮箱 → FreeRTOS 队列，见 lwIP 主系列 ch14 的裸机作业版）。 */
#ifndef F429_LWIP_ARCH_SYS_ARCH_H
#define F429_LWIP_ARCH_SYS_ARCH_H

#include <stdint.h>

typedef uint32_t sys_prot_t; /* SYS_ARCH_PROTECT 的保存槽；NO_SYS 下用默认空实现 */

#if !NO_SYS
#error "本工程只提供 NO_SYS=1 移植；OS 模型请补 sys_sem_t/sys_mbox_t/sys_thread_t + sys_arch.c"
#endif

#endif
