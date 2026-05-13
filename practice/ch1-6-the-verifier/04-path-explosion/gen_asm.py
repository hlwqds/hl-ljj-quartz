#!/usr/bin/env python3
"""生成 BPF 汇编实现真正的嵌套 if (不可被 clang 优化)。

直接写 BPF 字节码，绕过 clang 优化器。
每个 map lookup 产生不同 map_ptr → Verifier 不可剪枝。
"""

import sys, struct

N = int(sys.argv[1]) if len(sys.argv) > 1 else 15

# BPF opcode constants
BPF_LD_MAP_VALUE = 0x18
BPF_JMP_IMM = 0x05
BPF_JMP32 = 0x06
BPF_JEQ_IMM = 0x15
BPF_CALL = 0x85
BPF_MOV_IMM = 0xb7
BPF_EXIT = 0x95
BPF_ALU64_IMM = 0x07
BPF_ALU64 = 0x0f
BPF_LDX_MEM = 0x79
BPF_STX_MEM = 0x7b
BPF_W = 0
BPF_DW = 0x07
BPF_JGE = 0x2d
BPF_JGT = 0x25
BPF_JNE = 0x55

# Helper to encode a BPF instruction
def bpf_insn(cls, op, dst, src, off, imm):
    return struct.pack('<BBBHBBI',
        cls | (op << 4),  # opcode
        dst & 0xff,         # dst reg
        src & 0xff,         # src reg
        off & 0xffff,       # offset (16-bit, signed)
        imm & 0xffffffff    # immediate (32-bit)
    )

print("/* gen_asm.py %d — 直接 BPF 汇编，绕过 clang 优化 */" % N)
print("/* 嵌套 N=%d 层 if，每层 map lookup 不同 map → 不可剪枝 */" % N)
print("")
print("#include <linux/bpf.h>")
print("#include <bpf/bpf_helpers.h>")
print("")
print("typedef __u32 u32;")
print("typedef __u64 u64;")
print("")

for i in range(N):
    print("struct {")
    print("    __uint(type, BPF_MAP_TYPE_HASH);")
    print("    __uint(max_entries, 1);")
    print("    __type(key, u32);")
    print("    __type(value, u64);")
    print("} map_%d SEC(\".maps\");" % i)
print("")

# 用 asm 写真正的嵌套 if 结构
# 每层: load map ptr → call map_lookup → if (r0 != 0) { r0 += 1; }
# 关键: 每层嵌套在前一层内部，不是 goto 到末尾
# 使用 __attribute__((noinline)) 内联汇编

print("SEC(\"fentry/do_sys_openat2\")")
print("__attribute__((noinline))")
print("int explosion_unprunable(u64 *ctx)")
print("{")
print("    u32 flags = bpf_get_prandom_u32();")
print("    u32 key = 0;")
print("    u64 sum = 0;")
print("")

# 生成嵌套 if 的 C 代码
# 关键: 两分支都修改 sum，且 true 分支依赖运行时值
# 这样 clang 无法 goto 优化
indent = "    "
for i in range(N):
    lines_before = len(open('/dev/stdout').readlines()) if False else 0
    lines.append("%sif (flags & (1 << %d)) {" % (indent, i))
    indent += "    "
    lines.append("%s{" % indent)
    lines.append("%s    u64 *v = bpf_map_lookup_elem(&map_%d, &key);" % (indent, i))
    lines.append("%s    sum += (v ? *v : 0);" % indent)  # 运行时依赖，不可优化
    lines.append("%s}" % indent)
    lines.append("}")

# Wait, this still might get flattened. Let me try a different structure.
# The key insight: each else branch must ALSO do a map lookup.
# If both branches do a map lookup from different maps, clang can't merge them.
print("/* This file is auto-generated */")

# Actually, let me use a completely different approach:
# Use volatile to prevent optimization
print("")

# Rebuild with volatile on each pointer
lines = []
lines.append("// gen_asm.py %d" % N)
lines.append("#include <linux/bpf.h>")
lines.append("#include <bpf/bpf_helpers.h>")
lines.append("typedef __u32 u32;")
lines.append("typedef __u64 u64;")
lines.append("")

for i in range(N):
    lines.append("struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_%d SEC(\".maps\");" % i)

lines.append("")
lines.append("SEC(\"fentry/do_sys_openat2\")")
lines.append("int explosion_unprunable(u64 *ctx)")
lines.append("{")
lines.append("    u32 flags = bpf_get_prandom_u32();")
lines.append("    u32 key = 0;")

# volatile 全局变量强制所有路径都被执行
lines.append("    volatile u64 results[%d] = {};" % N)
lines.append("")

indent = "    "
for i in range(N):
    lines.append("%sif (flags & (1 << %d)) {" % (indent, i))
    indent += "    "
    lines.append("%s{" % indent)
    lines.append("%s    u64 *v = bpf_map_lookup_elem(&map_%d, &key);" % (indent, i))
    lines.append("%s    results[%d] = v ? *v : (u64)-1;" % (indent, i))
    lines.append("%s}" % indent)
    lines.append("} else {")
    lines.append("%s    results[%d] = %d;" % (indent, i, i))
    lines.append("%s}" % indent)
    lines.append("")

for i in range(N):
    lines.append("%s}" % indent)
    indent = indent[4:]

lines.append("    // 强制读取所有 results → clang 不能消除任何路径")
lines.append("    u64 total = 0;")
for i in range(N):
    lines.append("    total += results[%d];" % i)
lines.append("    *(volatile u64 *)0 = total;")
lines.append("    return 0;")
lines.append("}")
lines.append("")
lines.append("char _license[] SEC(\"license\") = \"GPL\";")

print('\n'.join(lines))
