/* bencode.h —— bencode 编解码（BEP 3：i42e / 4:spam / l…e / d…e，字典键有序） */
#ifndef BENCODE_H
#define BENCODE_H

#include <stddef.h>
#include <stdint.h>

struct bval {
    char type; /* 'i' 整数 's' 字节串 'l' 列表 'd' 字典 */
    long long i;
    char *s;
    size_t slen;
    struct bval **items; /* 列表元素 */
    size_t nitems;
    char **keys; /* 字典键（字节串，已按字典序排好） */
    struct bval **vals;
    size_t npairs;
};

/* 解码：从 buf 起解一个值，consumed 返回吃掉的字节数；失败返回 NULL */
struct bval *bdecode(const char *buf, size_t len, size_t *consumed);
/* 编码：字典键自动排序（规范形式——infohash 依赖这一点）；调用方 free 返回值 */
char *bencode(const struct bval *v, size_t *outlen);
/* 字典取值 */
struct bval *bget(struct bval *d, const char *key);
/* 整树释放 */
void bfree(struct bval *v);

/* 构造便捷函数（结果用 bfree 释放） */
struct bval *bint(long long v);
struct bval *bstr(const char *s, size_t len); /* len=SIZE_MAX → strlen */
struct bval *blist(void);
struct bval *bdict(void);
void bappend(struct bval *list, struct bval *item);          /* 列表追加 */
void bput(struct bval *dict, const char *key, struct bval *v); /* 字典放键值 */

#endif
