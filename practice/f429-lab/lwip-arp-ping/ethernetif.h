/* ethernetif.h —— 协议栈与 F429 ETH 硬件之间的移植层接口（ch21 三件套的声明） */
#ifndef F429_LWIP_ETHERNETIF_H
#define F429_LWIP_ETHERNETIF_H

#include "lwip/netif.h"

err_t ethernetif_init(struct netif *netif);  /* netif_add 的 init 回调 */
void  ethernetif_poll(struct netif *netif);  /* RX：描述符环 → pbuf → 栈 */
u8_t  eth_link_poll(void);                   /* BSR bit2（双读消锁存），1=Link Up */
void  eth_hw_init(void);                     /* ch20 成果：时钟/RMII/环/MAC/DMA 开张 */

#endif
