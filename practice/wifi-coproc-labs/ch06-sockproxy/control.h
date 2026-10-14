/* control.h —— 控制通道：TLV 命令编解码 + req_id 会话 + 扫描分片重组
 * 载荷跑在 ch03 帧层之上（type=CTRL_REQ / CTRL_RSP / EVENT）。
 */
#ifndef CONTROL_H
#define CONTROL_H

#include <stddef.h>
#include <stdint.h>

enum {
    CMD_PING = 0x01,
    CMD_STATUS = 0x02,
    CMD_SCAN = 0x03,
    CMD_JOIN = 0x04,
    CMD_DNS = 0x05,
    CMD_EVENT = 0x40, /* S3→F429 事件帧专用段 */
};

enum {
    EV_LINK_UP = 1,
    EV_LINK_DOWN = 2,
    EV_SCAN_DONE = 3,
    EV_SCAN_AP = 4, /* 单个 AP 的分片载荷 */
    EV_SOCK_DATA = 5,
    EV_SOCK_EOF = 6,
};

#define CTL_OK 0x00
#define CTL_E_PROTO 0x01 /* 协议层错误 */
#define CTL_E_STATE 0x02 /* 状态机不允许 */
#define CTL_E_APP 0x40 /* 应用层错误从这里起 */

/* TLV 读写游标（编码侧） */
struct tlvw {
    uint8_t *buf;
    size_t cap, len;
    int overflow;
};
void tlvw_init(struct tlvw *w, uint8_t *buf, size_t cap);
void tlvw_put(struct tlvw *w, uint8_t type, const void *val, uint16_t len);
void tlvw_put_u8(struct tlvw *w, uint8_t type, uint8_t v);
void tlvw_put_u16(struct tlvw *w, uint8_t type, uint16_t v);
void tlvw_put_u32(struct tlvw *w, uint8_t type, uint32_t v);

/* TLV 读取游标（解码侧）：顺序无关、未知 type 跳过 */
struct tlvr {
    const uint8_t *buf;
    size_t len, pos;
};
void tlvr_init(struct tlvr *r, const uint8_t *buf, size_t len);
int tlvr_next(struct tlvr *r, uint8_t *type, const uint8_t **val, uint16_t *len);

/* 请求/应答载荷布局：
 * REQ:  [cmd(2)][req_id(2)][参数 TLV…]
 * RSP:  [cmd(2)][req_id(2)][status(1)][结果 TLV…]
 * 全部网络序；提供拼装与拆开的便捷函数。 */
struct ctl_msg {
    uint16_t cmd, req_id;
    uint8_t status;
    uint8_t body[440]; /* 参数/结果区 */
    size_t bodylen;
};

size_t ctl_pack_req(const struct ctl_msg *m, uint8_t *out, size_t cap);
size_t ctl_pack_rsp(const struct ctl_msg *m, uint8_t *out, size_t cap);
/* 解析（REQ/RSP 都能解，靠帧 type 区分）；返回 0=格式非法 */
int ctl_parse(const uint8_t *in, size_t len, int is_rsp, struct ctl_msg *m);

/* 扫描分片重组器：EV_SCAN_AP 分片 → 攒齐回调 */
struct scan_reasm {
    uint8_t seen[64]; /* 片号位图（演示上限 64 片） */
    uint8_t total;
    uint8_t got;
    uint8_t buf[64][16]; /* 每片留 16B（SSID 摘要演示粒度） */
};
void scan_reasm_init(struct scan_reasm *s);
/* 收一片：[total(1)][index(1)][data(≤16)]；攒齐返回 1 */
int scan_reasm_feed(struct scan_reasm *s, const uint8_t *tlv_val, uint16_t tlv_len);

#endif
