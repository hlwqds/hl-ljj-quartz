/* port/support.c —— freestanding 支撑件：
 *   ① 极简 uart_printf（LWIP_PLATFORM_DIAG 的出口，%s/%c/%d/%u/%x/%p/%%）；
 *   ② -nostdlib 下 lwIP 会调用到的 libc 函数桩（编译器/库按 C11 freestanding
 *      约定只保证 memcpy/memmove/memset/memcmp/strlen 可用，其余按需补）；
 *   ③ sys_now()——lwIP 定时器的唯一时基，直接读 SysTick 心跳 g_ms。 */
#include <stdint.h>
#include <stdarg.h>
#include <stddef.h>
#include "lwip/arch.h" /* sys_prot_t（经 arch/cc.h）；其余 lwIP 类型按需 */

typedef uint32_t u32;

/* ---- USART1 PA9/PA10 @PCLK2=90MHz（与 main.c 的 uart_init 配套） ---- */
#define REG32(a)    (*(volatile u32 *)(a))
#define USART1_SR   REG32(0x40011000u + 0x00)
#define USART1_DR   REG32(0x40011000u + 0x04)

extern volatile u32 g_ms; /* main.c 的 SysTick 心跳 */

static void putc_(char c)
{
    while (!(USART1_SR & (1u << 7))) {}
    USART1_DR = (u32)(unsigned char)c;
}
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void putu(u32 v)
{
    char b[11]; int i = 10; b[10] = 0;
    if (!v) { putc_('0'); return; }
    while (v && i) { b[--i] = (char)('0' + v % 10u); v /= 10u; }
    puts_(&b[i]);
}
static void putx(u32 v)
{
    const char *d = "0123456789abcdef";
    for (int i = 28; i >= 0; i -= 4) putc_(d[(v >> i) & 0xF]);
}

/* 极简 printf：lwIP 的 DBG/ASSERT 只用到 %s %d %u %x %p %c —— 全实现 */
int uart_printf(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    for (; *fmt; fmt++) {
        if (*fmt != '%') { putc_(*fmt); continue; }
        fmt++;
        if (*fmt == 'l' && fmt[1] == 'd') { fmt++; putu((u32)va_arg(ap, long)); }
        else if (*fmt == 'l' && fmt[1] == 'u') { fmt++; putu((u32)va_arg(ap, unsigned long)); }
        else if (*fmt == 'l' && fmt[1] == 'x') { fmt++; putx((u32)va_arg(ap, unsigned long)); }
        else switch (*fmt) {
            case 's': { const char *s = va_arg(ap, const char *); puts_(s ? s : "(null)"); break; }
            case 'd': putu((u32)va_arg(ap, int)); break;          /* lwIP 尺寸下无负数困扰 */
            case 'u': putu(va_arg(ap, unsigned)); break;
            case 'x': putx(va_arg(ap, unsigned)); break;
            case 'p': puts_("0x"); putx((u32)(uintptr_t)va_arg(ap, void *)); break;
            case 'c': putc_((char)va_arg(ap, int)); break;
            case '%': putc_('%'); break;
            default:  putc_('%'); putc_(*fmt); break;
        }
    }
    va_end(ap);
    return 0;
}

/* ---- C11 freestanding 必备五件 + lwIP 用到的字符串族 ---- */
void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char *d = dst; const unsigned char *s = src;
    while (n--) { *d++ = *s++; }
    return dst;
}
void *memmove(void *dst, const void *src, size_t n)
{
    unsigned char *d = dst; const unsigned char *s = src;
    if (d < s) { while (n--) { *d++ = *s++; } }
    else { d += n; s += n; while (n--) { *--d = *--s; } }
    return dst;
}
void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = dst;
    while (n--) { *d++ = (unsigned char)c; }
    return dst;
}
int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *x = a, *y = b;
    while (n--) { if (*x != *y) { return *x - *y; } x++; y++; }
    return 0;
}
size_t strlen(const char *s) { size_t n = 0; while (s[n]) { n++; } return n; }
int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}
int strncmp(const char *a, const char *b, size_t n)
{
    while (n && *a && *a == *b) { a++; b++; n--; }
    return n ? (unsigned char)*a - (unsigned char)*b : 0;
}
char *strncpy(char *dst, const char *src, size_t n)
{
    size_t i = 0;
    for (; i < n && src[i]; i++) { dst[i] = src[i]; }
    for (; i < n; i++) { dst[i] = '\0'; }
    return dst;
}
char *strchr(const char *s, int c)
{
    for (;; s++) {
        if (*s == (char)c) { return (char *)s; }
        if (!*s) { return NULL; }
    }
}

/* netif_find() 按名字找网卡用的十进制后缀解析（"en0"→0） */
int atoi(const char *s)
{
    int v = 0, neg = 0;
    if (*s == '-') { neg = 1; s++; }
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
    return neg ? -v : v;
}

/* ---- lwIP 定时器时基：sys_check_timeouts() 每轮都来问现在几毫秒 ---- */
u32 sys_now(void) { return g_ms; }

/* ---- 临界区（SYS_LIGHTWEIGHT_PROT=1 的默认实现）：PRIMASK 存/关/恢复 ----
 * 纯轮询单上下文本用不上，但保持默认语义完整——升级实验一旦开中断（ETH_IRQn）
 * 它就是 pbuf 引用计数的安全带。*/
sys_prot_t sys_arch_protect(void)
{
    sys_prot_t pm;
    __asm volatile("mrs %0, primask" : "=r"(pm));
    __asm volatile("cpsid i" ::: "memory");
    return pm;
}
void sys_arch_unprotect(sys_prot_t p)
{
    __asm volatile("msr primask, %0" ::"r"(p) : "memory");
}
