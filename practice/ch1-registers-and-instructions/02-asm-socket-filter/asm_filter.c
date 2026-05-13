// 02-asm-socket-filter: Socket 过滤器 — 演示 BPF 指令集实际运用
//
// 对应文档 Section 7 - 代码实战：手动编写 eBPF 汇编
//
// 本程序实现一个识别 TCP/UDP 包的 Socket Filter。
// 用 C 编写，编译后可通过 llvm-objdump 观察对应的 BPF 指令：
//   - BPF_LDX: 从 ctx 加载 data/data_end 指针
//   - BPF_JMP: 边界检查、协议类型判断
//   - BPF_ALU: 指针算术
//   - BPF_EXIT: 返回放行/丢弃
//
// 编译: clang -O2 -target bpf -g -c asm_filter.c -o asm_filter.o
// 查看: llvm-objdump -d asm_filter.o

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <stddef.h>
#include <bpf/bpf_helpers.h>

typedef __u8 u8;
typedef __u16 u16;

// 内联汇编演示: 直接使用 BPF 内存访问指令
// 对应文档中的 BPF_LDX_MEM(BPF_H, dst, src, off)
static __always_inline u16 asm_read_u16(void *addr)
{
    u16 val;
    // BPF 内联汇编: 从内存加载 2 字节
    // 编译为一条 BPF_LDX_MEM 指令 (opcode class 00, BPF_H)
    asm volatile("r0 = *(u16 *)(r1 + 0)\n\t"
                 : "=r"(val)
                 : "r"(addr)
                 : "r0");
    return val;
}

SEC("socket")
int bpf_asm_filter(struct __sk_buff *skb)
{
    // === 步骤 1: 获取包数据指针 ===
    // 编译为两条 BPF_LDX 指令 (从 ctx 结构体加载)
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;

    // === 步骤 2: 边界检查 ===
    // 编译为 BPF_JMP 条件跳转指令 (BPF_JGT)
    // 如果 data + 14 > data_end 则跳转到返回 0
    if (data + sizeof(struct ethhdr) > data_end)
        return 0;  // 丢弃: 不足一个 Ethernet 头

    // === 步骤 3: 检查以太网协议类型 ===
    // 方法 A: 通过内联汇编直接读取 (演示 BPF_LDX 指令)
    struct ethhdr *eth = data;
    u16 eth_type = asm_read_u16(&eth->h_proto);

    // 编译为 BPF_JMP 条件跳转 (BPF_JNE)
    if (eth_type != 0x0008)  // IPv4 = 0x0800, 小端序为 0x0008
        return 0;

    // === 步骤 4: 检查 IP 协议字段 ===
    // Ethernet 头 (14) + IP 协议偏移 (9) = 23
    if (data + 24 > data_end)
        return 0;

    // 加载 IP 协议字段 → BPF_LDX_MEM(BPF_B, ...)
    u8 protocol = *((u8 *)data + 23);

    // 多次条件跳转 → 多条 BPF_JMP 指令
    if (protocol == 6)   // TCP
        return -1;       // 放行 (SOCKET_FILTER 约定: -1 = pass)
    if (protocol == 17)  // UDP
        return -1;

    // === 默认: 丢弃 ===
    // BPF_MOV: r0 = 0, 然后 BPF_EXIT
    return 0;
}

char _license[] SEC("license") = "GPL";
