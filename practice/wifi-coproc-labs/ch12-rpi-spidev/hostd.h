/* hostd.h —— 守护进程对外接口（fake 测试与 Linux 真机共用） */
#ifndef HOSTD_H
#define HOSTD_H

#include <stddef.h>
#include <stdint.h>

#include "framing.h"

struct transport; /* 前置声明：否则原型里的 struct 是"原型作用域"的另一家人，
                     与 transport.h 的文件作用域定义冲突（本工程首版踩过） */

extern struct fr_parser s_parser; /* hostd.c 内部使用（对端回喂） */

void hostd_init(struct transport *tr);
void hostd_poll(void);
int hostd_ping(uint32_t cookie);          /* 0=应答收到且 status OK */
int hostd_echo(const void *data, size_t n); /* 0=echo 事件逐字节一致 */

#endif
