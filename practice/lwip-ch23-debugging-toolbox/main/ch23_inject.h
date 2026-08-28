/*
 * lwIP 深度解析（二十三）：编译期注入头。
 *
 * 本文件经根 CMakeLists.txt 的 add_compile_options(-include ...) 被强制包含进
 * 所有组件的每个编译单元（含 .S 汇编），做两件事：
 *
 *   1. 定义 LWIP_HOOK_IP4_INPUT = ch23_ip4_input_hook：
 *      ip4.c 入口（ip4_input() 开头，ip4.c 中 "LWIP_HOOK_IP4_INPUT(p, inp)" 处）
 *      会调用 main/lab_main.c 里的 ch23_ip4_input_hook()。语义见 opt.h：
 *      返回非 0 表示 hook 已消费 pbuf（所有权移交，须自行 pbuf_free）；
 *      本工程永远返回 0 —— 纯观测，不改包。
 *
 *   2. debug 变体构建时（CONFIG_LWIP_DEBUG 在 sdkconfig 里打开），
 *      顺手点亮 TCP_RST_DEBUG：这是 tcp_in.c 两处 RST 决策点专用的模块宏
 *      （"tcp_input: no PCB match found, resetting." / "tcp_listen_input: ACK in LISTEN,
 *      sending reset"），IDF Kconfig 没有它的入口，只能编译期注入定义。
 *      #if !defined 顺序保证晚到的 opt.h 默认值(LWIP_DBG_OFF)不会覆盖我们。
 */
#ifndef PROJECT_CH23_INJECT_H
#define PROJECT_CH23_INJECT_H

#define LWIP_HOOK_IP4_INPUT ch23_ip4_input_hook

#ifdef CONFIG_LWIP_DEBUG
#ifndef TCP_RST_DEBUG
#define TCP_RST_DEBUG LWIP_DBG_ON
#endif /* TCP_RST_DEBUG */
#endif /* CONFIG_LWIP_DEBUG */

/* 本头被 -include 注入所有编译单元（含 .S 汇编），原型声明必须避开汇编预处理 */
#ifndef __ASSEMBLER__
struct pbuf;
struct netif;
int ch23_ip4_input_hook(struct pbuf *p, struct netif *inp);
#endif

#endif /* PROJECT_CH23_INJECT_H */
