/*
 * main.c -- UART 成帧协议实证：'$' seq ',' payload '*' xor '\n' 状态机
 *
 * 在 ch04-baremetal-template 上扩展 RX 侧：
 *   - CTRL 开 RX_EN（QEMU 模型：RX 未使能时字节在 chardev 层排队，不会丢）
 *   - 轮询 STATE.RXFULL，读 DATA 收字节（模型 RX 缓冲深度 = 1 字节）
 *   - 每字节喂给帧状态机，六类事件实时打印；payload=="STATS" 打印汇总
 *
 * 帧格式（NMEA 0183 风格）：
 *   '$' seq(2 hex) ',' payload(1..64) '*' csum(2 hex) '\n'
 *   csum = '$' 与 '*' 之间（含 seq 与逗号、含 payload）全部字节的异或
 *
 * 六类事件：OK / BADCS / GAP / OLONG / UNTERM / STRAY（见 ev_tag）
 *
 * 目标机型：qemu-system-arm -M mps2-an385（CMSDK APB UART0 @ 0x40004000）
 * 注入方式：-serial stdio，stdin 的每个字节原样进入 UART0 RX
 */

#include <stdint.h>

/* ---------- UART0 寄存器（依据 QEMU hw/char/cmsdk-apb-uart.c v10.1） ---------- */
#define UART0_BASE 0x40004000UL

#define UART0_DATA  (*(volatile uint32_t *)(UART0_BASE + 0x00)) /* 读=收 写=发 */
#define UART0_STATE (*(volatile uint32_t *)(UART0_BASE + 0x04)) /* 状态位       */
#define UART0_CTRL  (*(volatile uint32_t *)(UART0_BASE + 0x08)) /* 使能控制     */
#define UART0_DIV   (*(volatile uint32_t *)(UART0_BASE + 0x10)) /* 波特率分频   */

#define UART_STATE_TXFULL (1UL << 0) /* bit0：发送缓冲满           */
#define UART_STATE_RXFULL (1UL << 1) /* bit1：接收缓冲有数据       */
#define UART_CTRL_TX_EN   (1UL << 0)
#define UART_CTRL_RX_EN   (1UL << 1)

/* mps2-an385 UART 时钟 = SYSCLK = 25 MHz；BAUDDIV = 217 对应 115200 */
#define SYSCLK_HZ  25000000UL
#define UART_BAUD  115200UL
#define UART_BAUDDIV (SYSCLK_HZ / UART_BAUD) /* = 217 */

static void uart_init(void)
{
    /* 先使能后使用（ch04 教训：TX_EN=0 时写 DATA 被静默丢弃；RX 同理） */
    UART0_CTRL = UART_CTRL_TX_EN | UART_CTRL_RX_EN;
    UART0_DIV = UART_BAUDDIV;
}

static void uart_putc(char c)
{
    while (UART0_STATE & UART_STATE_TXFULL)
        ;
    UART0_DATA = (uint32_t)(uint8_t)c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void uart_puthex8(uint8_t v)
{
    static const char hex[] = "0123456789abcdef";
    uart_putc(hex[v >> 4]);
    uart_putc(hex[v & 0xF]);
}

/* 十进制打印：u32/10 用除法，链接期拉入 libgcc 的 __aeabi_uidiv（Makefile -lgcc） */
static void uart_putdec(uint32_t v)
{
    char buf[10]; /* u32 最大 10 位 */
    int i = 0;
    do {
        buf[i++] = (char)('0' + (v % 10));
        v /= 10;
    } while (v != 0);
    while (i > 0)
        uart_putc(buf[--i]);
}

/* 非阻塞收：有数据返回 1 并写出字节，否则返回 0（调用方自旋重试） */
static int uart_getc(uint8_t *c)
{
    if (UART0_STATE & UART_STATE_RXFULL) {
        *c = (uint8_t)UART0_DATA; /* 读 DATA 顺带清 RXFULL */
        return 1;
    }
    return 0;
}

/* ---------------- 帧接收状态机 ---------------- */

#define FSM_PAYLOAD_MAX 64 /* 帧长上限：超长即弃帧（防止垃圾撑爆缓冲） */

enum fsm_state {
    ST_SYNC,     /* 帧间：等待 '$'（杂散字节在此累计成段） */
    ST_SEQ,      /* 已见 '$'：收集 2 位 hex 序号 */
    ST_SEP,      /* 期望 ',' */
    ST_PAYLOAD,  /* 收 payload，直到 '*' */
    ST_CSUM_HI,  /* '*' 后校验高 4 位 */
    ST_CSUM_LO,  /* '*' 后校验低 4 位 */
    ST_END,      /* 期望 '\n'（帧完成判定） */
};

static const char *const st_name[] = {
    "SYNC", "SEQ", "SEP", "PAYLOAD", "CSUM_HI", "CSUM_LO", "END",
};

enum fsm_event {
    EV_OK = 0,  /* 完整帧且校验通过 */
    EV_BADCS,   /* 结构完整但校验不符 */
    EV_GAP,     /* 序号跳变（丢帧推断） */
    EV_OLONG,   /* payload 超长，保护性弃帧 */
    EV_UNTERM,  /* '\n' 在帧凑齐前到达（发送方截断/缓冲溢出） */
    EV_STRAY,   /* 杂散字节：帧间垃圾、帧内非法字符 */
    EV_COUNT
};

static const char *const ev_tag[EV_COUNT] = {
    "OK    ", "BADCS ", "GAP   ", "OLONG ", "UNTERM", "STRAY ",
};

static void ev_banner(uint8_t ev) /* 事件行统一前缀，如 "[BADCS]" */
{
    uart_putc('[');
    uart_puts(ev_tag[ev]);
    uart_putc(']');
}

struct fsm {
    /* 帧解析现场 */
    uint8_t  state;
    uint8_t  seq;          /* 本帧序号（2 hex 汇成） */
    uint8_t  want;         /* 期望的下一个序号 */
    uint8_t  have_want;    /* want 是否有效（首帧前无效） */
    uint8_t  nseq;         /* 已收序号 hex 位数 */
    uint8_t  acc;          /* '$' 与 '*' 之间字节的累计异或 */
    uint8_t  csum;         /* 帧内携带的校验字节 */
    uint16_t plen;         /* payload 已收长度 */
    char     payload[FSM_PAYLOAD_MAX + 1];
    uint16_t stray_run;    /* SYNC 态连续杂散字节数（成段汇报） */
    uint8_t  stray_last;

    /* 统计 */
    uint32_t nrx;          /* 收到的总字节数 */
    uint32_t cnt[EV_COUNT]; /* 各类事件次数 */
    uint32_t stray_bytes;  /* 杂散字节总数 */
    uint32_t lost;         /* GAP 推断的丢帧数 */
    uint32_t resync;       /* 弃帧/垃圾后重新锁定帧头的次数 */
};

static struct fsm g_fsm;

static void fsm_frame_start(struct fsm *f)
{
    f->state = ST_SEQ;
    f->nseq = 0;
    f->seq = 0;
    f->acc = 0; /* 校验覆盖 '$' 与 '*' 之间：从 seq 第一个字符起算 */
    f->plen = 0;
}

static void fsm_drop(struct fsm *f, uint8_t c)
{
    /* 帧内非法字符：弃帧。若该字节恰是 '$'，借势当作新帧头（真再同步） */
    f->cnt[EV_STRAY]++;
    f->stray_bytes++;
    f->resync++;
    ev_banner(EV_STRAY);
    uart_puts(" byte 0x");
    uart_puthex8(c);
    uart_puts(" in state ");
    uart_puts(st_name[f->state]);
    uart_puts(": frame dropped, resync\r\n");
    if (c == '$')
        fsm_frame_start(f);
    else
        f->state = ST_SYNC;
}

static int hexval(uint8_t c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return -1; /* 非法字符 */
}

static void print_stats(const struct fsm *f)
{
    uart_puts("---- rx stats ----\r\n");
    uart_puts("bytes rx     : ");
    uart_putdec(f->nrx);
    uart_puts("\r\n");
    for (int ev = 0; ev < EV_COUNT; ev++) {
        uart_puts(ev_tag[ev]);
        uart_puts(" events: ");
        uart_putdec(f->cnt[ev]);
        uart_puts("\r\n");
    }
    uart_puts("frames lost  : ");
    uart_putdec(f->lost);
    uart_puts(" (inferred from gaps)\r\n");
    uart_puts("junk bytes   : ");
    uart_putdec(f->stray_bytes);
    uart_puts("\r\nresyncs       : ");
    uart_putdec(f->resync);
    uart_puts("\r\n-----------------\r\n");
}

static int streq(const char *a, const char *b)
{
    while (*a != '\0' && *b != '\0') {
        if (*a++ != *b++)
            return 0;
    }
    return *a == *b;
}

static void fsm_feed(struct fsm *f, uint8_t c)
{
    int v;

    f->nrx++;

    /* 换行早到：除 SYNC（帧间换行，无害）与 END（正常终结）外，
     * 任何状态见到 '\n' 都说明帧被截断 */
    if (c == '\n' && f->state != ST_SYNC && f->state != ST_END) {
        f->cnt[EV_UNTERM]++;
        f->resync++;
        ev_banner(EV_UNTERM);
        uart_puts(" \\n at state ");
        uart_puts(st_name[f->state]);
        uart_puts(": frame cut short, dropped\r\n");
        f->state = ST_SYNC;
        return;
    }

    switch (f->state) {
    case ST_SYNC:
        if (c == '$') {
            if (f->stray_run > 0) { /* 成段汇报垃圾，不逐字节刷屏 */
                f->cnt[EV_STRAY]++;
                f->resync++;
                ev_banner(EV_STRAY);
                uart_putc(' ');
                uart_putdec(f->stray_run);
                uart_puts(" junk bytes (last 0x");
                uart_puthex8(f->stray_last);
                uart_puts(") skipped, locked at '$'\r\n");
                f->stray_run = 0;
            }
            fsm_frame_start(f);
        } else if (c != '\n' && c != '\r') {
            f->stray_run++;
            f->stray_bytes++;
            f->stray_last = c;
        }
        break;

    case ST_SEQ:
        v = hexval(c);
        if (v < 0) {
            fsm_drop(f, c);
        } else {
            f->acc ^= c;
            f->seq = (uint8_t)(f->seq * 16 + v);
            if (++f->nseq == 2)
                f->state = ST_SEP;
        }
        break;

    case ST_SEP:
        if (c == ',') {
            f->acc ^= c;
            f->state = ST_PAYLOAD;
        } else {
            fsm_drop(f, c);
        }
        break;

    case ST_PAYLOAD:
        if (c == '*') {
            f->state = ST_CSUM_HI;
            f->csum = 0;
        } else if (f->plen >= FSM_PAYLOAD_MAX) {
            /* 超长保护：立即弃帧。剩余 payload/校验/换行沦为帧间垃圾，
             * 由 SYNC 态成段计数，直到下一个 '$' 再同步 */
            f->cnt[EV_OLONG]++;
            f->resync++;
            ev_banner(EV_OLONG);
            uart_puts(" payload > ");
            uart_putdec(FSM_PAYLOAD_MAX);
            uart_puts(" bytes: frame dropped\r\n");
            f->state = ST_SYNC;
        } else {
            f->acc ^= c;
            f->payload[f->plen++] = (char)c;
        }
        break;

    case ST_CSUM_HI:
        v = hexval(c);
        if (v < 0) {
            fsm_drop(f, c);
        } else {
            f->csum = (uint8_t)(v << 4);
            f->state = ST_CSUM_LO;
        }
        break;

    case ST_CSUM_LO:
        v = hexval(c);
        if (v < 0) {
            fsm_drop(f, c);
        } else {
            f->csum |= (uint8_t)v;
            f->state = ST_END; /* 只差 '\n' */
        }
        break;

    case ST_END:
        if (c != '\n') { /* 到了这里居然不是换行：结构崩坏 */
            fsm_drop(f, c);
            break;
        }
        if (f->csum != f->acc) {
            f->cnt[EV_BADCS]++;
            ev_banner(EV_BADCS);
            uart_puts(" frame seq ");
            uart_puthex8(f->seq);
            uart_puts(" csum got 0x");
            uart_puthex8(f->csum);
            uart_puts(" want 0x");
            uart_puthex8(f->acc);
            uart_puts(": dropped\r\n");
        } else {
            if (f->have_want && f->seq != f->want) {
                uint8_t gap = (uint8_t)(f->seq - f->want);
                f->cnt[EV_GAP]++;
                f->lost += gap;
                ev_banner(EV_GAP);
                uart_puts(" seq ");
                uart_puthex8(f->want);
                uart_puts(" -> ");
                uart_puthex8(f->seq);
                uart_putc(':');
                uart_putdec(gap);
                uart_puts(" frame(s) missing (inferred)\r\n");
            }
            f->cnt[EV_OK]++;
            f->payload[f->plen] = '\0';
            ev_banner(EV_OK);
            uart_puts(" seq ");
            uart_puthex8(f->seq);
            uart_putc(' ');
            uart_putdec(f->plen);
            uart_puts("B '");
            uart_puts(f->payload);
            uart_puts("'\r\n");
            if (streq(f->payload, "STATS"))
                print_stats(f); /* 命令帧：请求方拉取统计 */
        }
        /* 策略：结构完整的帧（无论校验对错）都推进期望序号——
         * BADCS 已单列计数；若错误恰落在 seq 字节，GAP 可能少报一次，
         * 两类事件本就有交叠，统计口径以"序号推进"为准 */
        f->want = (uint8_t)(f->seq + 1);
        f->have_want = 1;
        f->state = ST_SYNC;
        break;
    }
}

int main(void)
{
    uart_init();

    uart_puts("\r\nch06 uart framing receiver on mps2-an385\r\n");
    uart_puts("frame := '$' seq(2hex) ',' payload '*' xor(2hex) '\\n'\r\n");
    uart_puts("feed stdin -> uart0 rx; send a STATS frame for counters\r\n");

    g_fsm.state = ST_SYNC; /* 其余字段在 .bss，Reset_Handler 已清零 */

    for (;;) {
        uint8_t c;
        if (uart_getc(&c))
            fsm_feed(&g_fsm, c);
        /* 轮询版自旋烧 CPU：ch07 换 RX 中断 + 环形缓冲，
         * ch08 加帧间超时（时间基准）后可发现"发一半死掉"的发送方 */
    }
}
