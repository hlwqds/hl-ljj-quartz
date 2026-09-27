/* lwipopts.h —— NO_SYS=1 裸机裁剪（ch21 表格逐项落地）
 *
 * 原则：跟章节走——阶段②③只要 ARP+ICMP+raw；TCP/UDP/socket/DHCP 全关，
 * ch22 打流实验要 TCP 时回来开 LWIP_TCP（并把 PBUF/MEM 预算重算一遍）。 */
#ifndef F429_LWIP_LWIPOPTS_H
#define F429_LWIP_LWIPOPTS_H

/* ---- 模型：无 OS，主循环即事件循环 ---- */
#define NO_SYS               1
#define LWIP_NO_CTYPE_H      1   /* freestanding：用 lwIP 自带的 isdigit 等内联实现，
                                  * 不拖 newlib 的 _ctype_ 表进来 */

/* ---- 协议：章节主角 ---- */
#define LWIP_IPV4            1
#define LWIP_ARP             1   /* etharp_output：第一声 ARP 的填表人 */
#define LWIP_ICMP            1   /* 收到 echo request 自动回 reply（零应用代码） */
#define LWIP_RAW             1   /* 手搓 ping 的通道（raw pcb 回调） */
#define LWIP_ETHERNET        1   /* ethernet_input 帧解析 */

/* ---- 本章不用的全关（负空间也是裁剪） ---- */
#define LWIP_TCP             0   /* ch22 打流再开 */
#define LWIP_UDP             0
#define LWIP_DHCP            0   /* 静态 IP；升级实验 NO_SYS=0 时换 dhcp_start */
#define LWIP_DNS             0
#define LWIP_IGMP            0
#define LWIP_AUTOIP          0
#define LWIP_IPV6            0
#define LWIP_NETCONN         0   /* 要 OS 层 */
#define LWIP_SOCKET          0   /* 要 OS 层 */

/* ---- 内存预算（章节表格 + 1536 池块） ---- */
#define MEM_SIZE             (16 * 1024) /* mem 堆：pbuf 结构壳等小对象 */
#define PBUF_POOL_SIZE       8           /* 收帧池：环深 4 的两倍余量 */
#define PBUF_POOL_BUFSIZE    1536        /* 整帧一池块，一跳 memcpy 不分段 */
#define MEMP_NUM_RAW_PCB     2
#define MEMP_NUM_ARP_QUEUE   4

/* ---- 统计：pbuf 池深够不够、丢没丢帧，实测核销全靠它（章节清单#3） ---- */
#define LWIP_STATS           1
#define LWIP_STATS_DISPLAY   1
#define LINK_STATS           1

/* ---- 打开 lwIP 内部调试的方法（章节「ARP 状态行」实测用）：
 * 取消下面注释后 LWIP_PLATFORM_DIAG 会把 DBG 输出打到串口。
 * #define LWIP_DEBUG
 * #define ETHARP_DEBUG  LWIP_DBG_ON
 * #define ICMP_DEBUG    LWIP_DBG_ON
 * #define DEBUG_LWIP_FILENAME 1  -- 可选：输出断言/日志的源文件名
 */
#endif
