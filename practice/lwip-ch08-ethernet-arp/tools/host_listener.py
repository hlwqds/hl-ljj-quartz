#!/usr/bin/env python3
"""ch8 实验宿主机侧配套：在 127.0.0.1:8108 上做高并发的 accept/close 服务。

SLIRP 用户态网络把 10.0.2.2 映射为宿主机 loopback 别名：guest 对
10.0.2.2:8108 的 TCP 连接会落在本服务上。每个 accept 一个线程、立即关闭，
专为"反复建连测首包延迟"设计。
"""
import socket
import threading


def handle(conn):
    try:
        conn.recv(16)
    except OSError:
        pass
    conn.close()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 8108))
    srv.listen(128)
    print("listening on 127.0.0.1:8108")
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
