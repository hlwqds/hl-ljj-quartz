# ex07 sntp-clock —— 根工程文件（MINIMAL 形态，全部依赖来自 ${IDF_PATH}）
#
# 关键编译期改动：SNTP_PORT=8260 全局覆盖。
#   lwIP 的 SNTP 客户端把「本地绑定端口」与「远端目的端口」绑死在同一个
#   SNTP_PORT（sntp_opts.h 默认 123，sntp.c:575 udp_sendto / sntp.c:701 udp_bind）。
#   SLIRP 的外连转发是"同端口号落宿主 loopback"，123 又是特权端口——于是把
#   号段内的 8260 作为编期覆盖值：guest 的 SNTP 报文从/到 8260，宿主侧
#   tools/ntpd.py 免 root 监听 8260 即可形成闭环（README 裁决小节详述）。
# 该定义必须加在 include(project.cmake) 之前才能传给 lwip 组件源码；是否生效
# 可在 build/compile_commands.json 里 grep -DSNTP_PORT 取证（README 有记录）。
add_compile_definitions(SNTP_PORT=8260)

cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(ex07_sntp_clock)
