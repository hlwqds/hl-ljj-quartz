# 断在 tcp_alloc：观察"谁的邮箱消息让我分配 PCB"——tcpip 单线程暗线的活证据
set pagination off
set confirm off
target remote :1234
break tcp_alloc
continue
printf "\n===== first tcp_alloc() hit, caller chain =====\n"
bt 12
info locals
p prio
detach
quit
