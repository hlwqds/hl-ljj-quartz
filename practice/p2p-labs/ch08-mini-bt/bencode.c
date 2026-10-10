/* bencode.c —— bencode 编解码实现（教科书式递归下降，无外部依赖） */
#include "bencode.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct bval *bint(long long v)
{
    struct bval *b = calloc(1, sizeof *b);
    b->type = 'i', b->i = v;
    return b;
}

struct bval *bstr(const char *s, size_t len)
{
    struct bval *b = calloc(1, sizeof *b);
    b->type = 's';
    b->slen = len == (size_t)-1 ? strlen(s) : len;
    b->s = malloc(b->slen ? b->slen : 1);
    memcpy(b->s, s, b->slen);
    return b;
}

struct bval *blist(void)
{
    struct bval *b = calloc(1, sizeof *b);
    b->type = 'l';
    return b;
}

struct bval *bdict(void)
{
    struct bval *b = calloc(1, sizeof *b);
    b->type = 'd';
    return b;
}

void bappend(struct bval *l, struct bval *item)
{
    l->items = realloc(l->items, sizeof(void *) * (l->nitems + 1));
    l->items[l->nitems++] = item;
}

void bput(struct bval *d, const char *key, struct bval *v)
{
    d->keys = realloc(d->keys, sizeof(char *) * (d->npairs + 1));
    d->vals = realloc(d->vals, sizeof(void *) * (d->npairs + 1));
    d->keys[d->npairs] = strdup(key);
    d->vals[d->npairs] = v;
    d->npairs++;
}

void bfree(struct bval *v)
{
    if (!v)
        return;
    if (v->type == 's')
        free(v->s);
    for (size_t i = 0; i < v->nitems; i++)
        bfree(v->items[i]);
    free(v->items);
    for (size_t i = 0; i < v->npairs; i++) {
        free(v->keys[i]);
        bfree(v->vals[i]);
    }
    free(v->keys), free(v->vals);
    free(v);
}

/* ---- 解码 ---- */

static struct bval *decode_rec(const char **pp, const char *end)
{
    const char *p = *pp;
    if (p >= end)
        return NULL;
    if (*p == 'i') { /* i123e */
        char *e;
        long long v = strtoll(p + 1, &e, 10);
        if (e >= end || *e != 'e')
            return NULL;
        *pp = e + 1;
        return bint(v);
    }
    if (*p >= '0' && *p <= '9') { /* 4:spam */
        char *e;
        long len = strtol(p, &e, 10);
        if (e >= end || *e != ':' || e + 1 + len > end || len < 0)
            return NULL;
        struct bval *b = bstr(e + 1, (size_t)len);
        *pp = e + 1 + len;
        return b;
    }
    if (*p == 'l' || *p == 'd') {
        struct bval *c = *p == 'l' ? blist() : bdict();
        p++;
        while (p < end && *p != 'e') {
            if (c->type == 'l') {
                *pp = p;
                struct bval *item = decode_rec(pp, end);
                if (!item) {
                    bfree(c);
                    return NULL;
                }
                bappend(c, item);
                p = *pp;
            } else { /* 字典：键必为字节串 */
                *pp = p;
                struct bval *k = decode_rec(pp, end);
                if (!k || k->type != 's') {
                    bfree(k), bfree(c);
                    return NULL;
                }
                p = *pp;
                struct bval *v = decode_rec(pp, end);
                if (!v) {
                    bfree(k), bfree(c);
                    return NULL;
                }
                /* 键收成 C 字符串（截断到 127 字节——种子文件的键全是短 ASCII） */
                char keyz[128];
                snprintf(keyz, sizeof keyz, "%.*s", (int)(k->slen < 127 ? k->slen : 127),
                         k->s);
                bput(c, keyz, v);
                bfree(k);
                p = *pp;
            }
        }
        if (p >= end || *p != 'e') {
            bfree(c);
            return NULL;
        }
        *pp = p + 1;
        return c;
    }
    return NULL;
}

struct bval *bdecode(const char *buf, size_t len, size_t *consumed)
{
    const char *p = buf;
    struct bval *v = decode_rec(&p, buf + len);
    if (v && consumed)
        *consumed = (size_t)(p - buf);
    return v;
}

struct bval *bget(struct bval *d, const char *key)
{
    if (!d || d->type != 'd')
        return NULL;
    for (size_t i = 0; i < d->npairs; i++)
        if (!strcmp(d->keys[i], key))
            return d->vals[i];
    return NULL;
}

/* ---- 编码（字典键排序：规范形式，infohash 的前提） ---- */

static int cmp_key(const void *a, const void *b)
{
    return strcmp(*(char *const *)a, *(char *const *)b);
}

static void enc_rec(const struct bval *v, char **out, size_t *len, size_t *cap)
{
    char tmp[64];
    int n;
#define PUT(s, l)                                                                              \
    do {                                                                                       \
        while (*len + (l) > *cap)                                                              \
            *out = realloc(*out, *cap *= 2);                                                   \
        memcpy(*out + *len, s, l), *len += (l);                                                \
    } while (0)

    switch (v->type) {
    case 'i':
        n = snprintf(tmp, sizeof tmp, "i%llde", v->i);
        PUT(tmp, (size_t)n);
        break;
    case 's':
        n = snprintf(tmp, sizeof tmp, "%zu:", v->slen);
        PUT(tmp, (size_t)n);
        PUT(v->s, v->slen);
        break;
    case 'l':
        PUT("l", 1);
        for (size_t i = 0; i < v->nitems; i++)
            enc_rec(v->items[i], out, len, cap);
        PUT("e", 1);
        break;
    case 'd': {
        size_t idx[64];
        size_t np = v->npairs < 64 ? v->npairs : 64;
        for (size_t i = 0; i < np; i++)
            idx[i] = i;
        for (size_t i = 0; i < np; i++) /* 小字典冒泡排序足矣 */
            for (size_t j = i + 1; j < np; j++)
                if (cmp_key(&v->keys[idx[j]], &v->keys[idx[i]]) < 0) {
                    size_t t = idx[i];
                    idx[i] = idx[j];
                    idx[j] = t;
                }
        PUT("d", 1);
        for (size_t i = 0; i < np; i++) {
            size_t k = idx[i];
            size_t klen = strlen(v->keys[k]);
            n = snprintf(tmp, sizeof tmp, "%zu:", klen);
            PUT(tmp, (size_t)n);
            PUT(v->keys[k], klen);
            enc_rec(v->vals[k], out, len, cap);
        }
        PUT("e", 1);
        break;
    }
    }
#undef PUT
}

char *bencode(const struct bval *v, size_t *outlen)
{
    size_t cap = 256, len = 0;
    char *out = malloc(cap);
    enc_rec(v, &out, &len, &cap);
    if (outlen)
        *outlen = len;
    return out;
}
