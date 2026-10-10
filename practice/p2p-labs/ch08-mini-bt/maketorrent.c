/* maketorrent.c —— 造种机：文件 → .torrent（系列 ch08 §8.1）
 *
 * 与真实工具对齐的部分：bencode 规范形式（字典键排序）、info 字典结构
 * （piece length / pieces 拼接 SHA-1 / name / length）、infohash = SHA-1(bencode(info))。
 * 简化：只支持单文件种子、HTTP announce 一条。

 * 用法：./maketorrent <文件> <announce地址> [输出.torrent] [分片字节数=32768]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bencode.h"
#include "sha1.h"

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "用法: %s <文件> <announce> [输出.torrent] [分片字节=32768]\n",
                argv[0]);
        return 1;
    }
    const char *path = argv[1], *announce = argv[2];
    char outp[512];
    snprintf(outp, sizeof outp, "%s", argc > 3 ? argv[3] : "out.torrent");
    long piece_len = argc > 4 ? atol(argv[4]) : 32768;
    if (piece_len < 1024)
        piece_len = 32768;

    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *blob = malloc(sz);
    fread(blob, 1, sz, f);
    fclose(f);

    long npieces = (sz + piece_len - 1) / piece_len;
    char *pieces = malloc(npieces * 20);
    for (long i = 0; i < npieces; i++) {
        long off = i * piece_len;
        long len = sz - off < piece_len ? sz - off : piece_len;
        sha1(blob + off, (size_t)len, (unsigned char *)pieces + i * 20);
    }

    /* info 字典（键序即 bencode 规范要求的字典序） */
    struct bval *info = bdict();
    bput(info, "length", bint(sz));
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    const char *bs2 = strrchr(base, '\\'); /* Windows 路径 */
    if (bs2)
        base = bs2 + 1;
    bput(info, "name", bstr(base, (size_t)-1));
    bput(info, "piece length", bint(piece_len));
    bput(info, "pieces", bstr(pieces, (size_t)npieces * 20));

    struct bval *t = bdict();
    bput(t, "announce", bstr(announce, (size_t)-1));
    bput(t, "info", info);

    size_t tlen;
    char *enc = bencode(t, &tlen);
    FILE *o = fopen(outp, "wb");
    fwrite(enc, 1, tlen, o);
    fclose(o);

    /* infohash 单独编码 info 字典再哈希——种子文件全文哈希是初学者最常见错误 */
    size_t ilen;
    char *ienc = bencode(info, &ilen);
    unsigned char ih[20];
    char hx[41];
    sha1(ienc, ilen, ih);
    sha1_hex(ih, hx);

    printf("[maketorrent] %s：\n  %ld B = %ld 片 × %ld B（末片 %ld B）\n"
           "  announce %s\n  infohash %s\n  已写 %s（%zu B）\n",
           base, sz, npieces, piece_len,
           sz - (npieces - 1) * piece_len, announce, hx, outp, tlen);
    return 0;
}
