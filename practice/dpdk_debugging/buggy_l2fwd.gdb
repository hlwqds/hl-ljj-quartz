# buggy_l2fwd.gdb — 配合 buggy_l2fwd 使用的 GDB 调试脚本
#
# 用法:
#   gdb -x buggy_l2fwd.gdb ./build/buggy_l2fwd /tmp/core-buggy_l2fwd-XXX
#
# 或者 attach 运行中的进程:
#   gdb -x buggy_l2fwd.gdb -p $(pidof buggy_l2fwd)
#
# 加载后会自动执行 setup 命令

set pagination off
set print pretty on
set print array on
set scheduler-locking on

# ========== DPDK 自定义命令 ==========

# 漂亮打印 rte_mbuf
define dpdk-mbuf
    printf "=== rte_mbuf %p ===\n", $arg0
    printf "  buf_addr    = %p\n", $arg0->buf_addr
    printf "  buf_iova    = 0x%lx\n", $arg0->buf_iova
    printf "  buf_len     = %u\n", $arg0->buf_len
    printf "  data_off    = %u\n", $arg0->data_off
    printf "  data_len    = %u\n", $arg0->data_len
    printf "  pkt_len     = %u\n", $arg0->pkt_len
    printf "  nb_segs     = %u\n", $arg0->nb_segs
    printf "  next        = %p\n", $arg0->next
    printf "  ol_flags    = 0x%lx\n", $arg0->ol_flags
    printf "  packet_type = 0x%x\n", $arg0->packet_type
    printf "  refcnt      = %u\n", $arg0->refcnt
end
document dpdk-mbuf
    Print key fields of a rte_mbuf pointer. Usage: dpdk-mbuf <mbuf_ptr>
end

# 漂亮打印 rte_mempool
define dpdk-mempool
    printf "=== rte_mempool %s (%p) ===\n", $arg0->name, $arg0
    printf "  size         = %u\n", $arg0->size
    printf "  cache_size   = %u\n", $arg0->cache_size
    printf "  priv_size    = %u\n", $arg0->priv_size
    printf "  flags        = 0x%x\n", $arg0->flags
    printf "  populated    = %u\n", $arg0->populated_size
    printf "  avail        = %u\n", *(volatile uint32_t *)$arg0->pool_data
end
document dpdk-mempool
    Print rte_mempool summary. Usage: dpdk-mempool <pool_ptr>
end

# 漂亮打印 rte_ring
define dpdk-ring
    printf "=== rte_ring %s (%p) ===\n", $arg0->name, $arg0
    printf "  size        = %u\n", $arg0->size
    printf "  mask        = 0x%x\n", $arg0->mask
    printf "  prod.head   = %u\n", $arg0->prod.head
    printf "  prod.tail   = %u\n", $arg0->prod.tail
    printf "  cons.head   = %u\n", $arg0->cons.head
    printf "  cons.tail   = %u\n", $arg0->cons.tail
    printf "  used        = %u\n", ($arg0->prod.tail - $arg0->cons.head) & $arg0->mask
end
document dpdk-ring
    Print rte_ring state. Usage: dpdk-ring <ring_ptr>
end

# 漂亮打印 rte_eth_dev
define dpdk-ethdev
    printf "=== rte_eth_dev %p ===\n", $arg0
    printf "  data->name  = %s\n", $arg0->data->name
    printf "  data->port_id = %u\n", $arg0->data->port_id
    printf "  data->nb_rx_queues = %u\n", $arg0->data->nb_rx_queues
    printf "  data->nb_tx_queues = %u\n", $arg0->data->nb_tx_queues
    printf "  data->dev_link.link_status = %u\n", $arg0->data->dev_link.link_status
end
document dpdk-ethdev
    Print rte_eth_dev state. Usage: dpdk-ethdev <dev_ptr>
end

# 反汇编当前函数 (跳过 DPDK 内部)
define dpdk-where
    backtrace 30
    frame 0
    info registers
end
document dpdk-where
    Print full backtrace + registers of current frame
end

# 查看 mbuf 数据区 (前 N 字节)
define dpdk-mbuf-data
    set $mbuf = $arg0
    set $len = $arg1
    if $len > 128
        set $len = 128
    end
    printf "mbuf data (%u bytes):\n", $len
    x/$lenxb ($mbuf->buf_addr + $mbuf->data_off)
end
document dpdk-mbuf-data
    Print mbuf data payload as hex. Usage: dpdk-mbuf-data <mbuf> <bytes>
end

# 一次性看全部 lcore 栈
define dpdk-all-stacks
    printf "\n=== All lcore stacks ===\n"
    info threads
    thread apply all bt 15
end
document dpdk-all-stacks
    Print backtrace of all threads (lcores)
end

# ========== 调试场景预设 ==========

# 场景 1: crash 后第一时间
define crash-triage
    printf "\n=== Crash Triage ===\n"
    bt full
    printf "\n--- Current frame locals ---\n"
    info locals
    printf "\n--- All registers ---\n"
    info registers
    printf "\n--- Recent watchpoints ---\n"
    info watchpoints
end
document crash-triage
    Run standard crash triage sequence: bt full + locals + registers
end

# 场景 2: mbuf 异常时的快速诊断
define mbuf-debug
    if $argc == 0
        printf "Usage: mbuf-debug <mbuf_ptr> [field]\n"
    else
        dpdk-mbuf $arg0
        printf "--- First 64 bytes of data ---\n"
        x/64xb ($arg0->buf_addr + $arg0->data_off)
    end
end
document mbuf-debug
    Run mbuf diagnostic: fields + data hex dump
end

# 加载完成提示
printf "\n=== DPDK GDB scripts loaded ===\n"
printf "Available commands:\n"
printf "  dpdk-mbuf      <ptr>            - print mbuf fields\n"
printf "  dpdk-mempool   <ptr>            - print mempool state\n"
printf "  dpdk-ring      <ptr>            - print ring state\n"
printf "  dpdk-ethdev    <ptr>            - print ethdev state\n"
printf "  dpdk-mbuf-data <mbuf> <bytes>   - hex dump mbuf data\n"
printf "  dpdk-where                       - bt + registers of current frame\n"
printf "  dpdk-all-stacks                  - all thread backtraces\n"
printf "  crash-triage                     - one-shot crash diagnosis\n"
printf "  mbuf-debug     <mbuf_ptr>       - mbuf field + data dump\n"
printf "\n"
