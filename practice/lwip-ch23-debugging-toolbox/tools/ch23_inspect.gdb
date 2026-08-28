# lwIP 深度解析（二十三）：gdb 活体 PCB 巡检脚本
# 用法：QEMU 以 -s 启动后，
#   xtensa-esp32-elf-gdb -batch -x tools/ch23_inspect.gdb build/lwip_ch23_debugging_toolbox.elf
set pagination off
set confirm off

# target remote 会先打断目标（qemu 的 gdbserver 行为）
target remote :1234

printf "\n===== core / current tasks =====\n"
info threads
p pxCurrentTCBs[0]->pcTaskName
p pxCurrentTCBs[1]->pcTaskName

printf "\n===== LISTEN pcbs =====\n"
set var $l = (struct tcp_pcb_listen *)tcp_listen_pcbs.pcbs
while $l != 0
  printf "LISTEN port=%d backlog=%d accepts_pending=%d next=%p\n", $l->local_port, $l->backlog, $l->accepts_pending, $l->next
  set var $l = (struct tcp_pcb_listen *)$l->next
end

printf "\n===== ACTIVE pcbs =====\n"
set var $a = tcp_active_pcbs
while $a != 0
  printf "ACTIVE state=%d lport=%d rport=%d next=%p\n", $a->state, $a->local_port, $a->remote_port, $a->next
  set var $a = $a->next
end

printf "\n===== TIME_WAIT pcbs =====\n"
set var $t = tcp_tw_pcbs
while $t != 0
  printf "TW lport=%d rport=%d next=%p\n", $t->local_port, $t->remote_port, $t->next
  set var $t = $t->next
end

printf "\n===== loopback queue on 'lo' netif =====\n"
p loop_netif.name
p loop_netif.loop_first
p loop_netif.loop_cnt_current

printf "\n===== stats snapshot =====\n"
p lwip_stats.tcp.xmit
p lwip_stats.tcp.recv
p lwip_stats.tcp.drop

detach
quit
