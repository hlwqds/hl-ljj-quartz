# lwip-ch16-socket-netconn-vfs

《lwIP 深度解析（十六）》实验工程：socket / netconn / VFS。

基于系列 ch3 联网模板（openeth bring-up + DHCP），全部测量在 guest 内部
127.0.0.1 回环完成，排除 SLIRP 干扰。IDF v6.0.2 全默认 lwIP 配置
（MAX_SOCKETS=10 / FD_SETSIZE=64 / TCP_RECVMBOX=6），唯一非默认项：
`CONFIG_ETH_USE_OPENETH=y`（QEMU openeth 驱动）。

四个阶段（`main/lab_main.c`）：

1. **PHASE A** 分层成本标定：64B RTT 与 105KB 有界流水线吞吐，
   socket 栈 vs netconn 栈各 3 轮；
2. **PHASE B** VFS 集成验证：fd 值域（54 起）、fstat(S_IFSOCK)、
   POSIX read/write 直操作 socket、双连接 poll、FIONREAD 门控行为；
3. **PHASE C** 故障注入·fd 耗尽：循环 socket() 触发 ENFILE 临界、
   close 后槽位回收时延；
4. **PHASE D** 故障注入·阻塞 recv 窒息：跨任务 close 解救 /
   SO_RCVTIMEO / O_NONBLOCK / select(timeout) 四种处境对照。

构建与运行见 `practice/lwip-labs/CONVENTIONS.md` 第 3 节；QEMU hostfwd
按章号约定使用 `hostfwd=tcp::8018-:8888`。实验输出在 `run.log`。
