/*
 * lwIP 深度解析（十一）：编译期注入的 IP4 输入 hook 原型。
 *
 * 本头文件通过 main/CMakeLists.txt 里的
 *   target_compile_options(lwip PRIVATE -include <本文件>)
 * 强制包含进 lwIP 组件的每个编译单元。ip4.c 里的
 *   #ifdef LWIP_HOOK_IP4_INPUT → LWIP_HOOK_IP4_INPUT(p, inp)
 * 因此会调用 state_lab.c 定义的 ch11_ip4_input_hook()，
 * 语义见 opt.h：返回非 0 表示 hook 已消费 pbuf（所有权移交，需自行释放）。
 */
#ifndef PROJECT_CH11_HOOK_DECL_H
#define PROJECT_CH11_HOOK_DECL_H

#define LWIP_HOOK_IP4_INPUT ch11_ip4_input_hook

/* 本头被 add_compile_options(-include ...) 注入所有编译单元（含 .S 汇编），
 * 原型声明必须避开汇编预处理。 */
#ifndef __ASSEMBLER__
struct pbuf;
struct netif;
int ch11_ip4_input_hook(struct pbuf *p, struct netif *inp);
#endif

#endif /* PROJECT_CH11_HOOK_DECL_H */
