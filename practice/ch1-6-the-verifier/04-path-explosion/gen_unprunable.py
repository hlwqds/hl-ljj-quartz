#!/usr/bin/env python3
"""生成不可被 clang 扁平化的嵌套 if。
技巧: volatile 数组 + 两分支都写入 → clang 不能 goto 跳过。"""

import sys

N = int(sys.argv[1]) if len(sys.argv) > 1 else 15

L = []
L.append("// gen_unprunable.py %d — volatile 数组阻止 clang 扁平化" % N)
L.append("#include <linux/bpf.h>")
L.append("#include <bpf/bpf_helpers.h>")
L.append("typedef __u32 u32; typedef __u64 u64;")
L.append("")

for i in range(N):
    L.append("struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_%d SEC(\".maps\");" % i)

L.append("")
L.append("SEC(\"fentry/do_sys_openat2\")")
L.append("int explosion_unprunable(u64 *ctx)")
L.append("{")

L.append("    u32 flags = bpf_get_prandom_u32();")
L.append("    u32 key = 0;")
L.append("    volatile u64 r[%d];" % N)
L.append("")

indent = "    "
for i in range(N):
    L.append("%sif (flags & (1 << %d)) {" % (indent, i))
    indent += "    "
    L.append("%s    u64 *v = bpf_map_lookup_elem(&map_%d, &key);" % (indent, i))
    L.append("%s    r[%d] = v ? *v : (u64)-1;" % (indent, i))
    L.append("%s} else {" % indent)
    L.append("%s    r[%d] = %d;" % (indent, i, i))

for i in range(N):
    L.append("%s}" % indent)
    indent = indent[4:]

L.append("    *(volatile u64 *)0 = 0;")
L.append("    return 0;")
L.append("}")
L.append("")
L.append("char _license[] SEC(\"license\") = \"GPL\";")

print('\n'.join(L))
