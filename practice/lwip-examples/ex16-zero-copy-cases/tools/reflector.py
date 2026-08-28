#!/usr/bin/env python3
"""ex16 宿主反射器（可选路径）：监听 8331，把收到的字节原样回显。

用途：固件侧 CONFIG_ZC_HOST_REFLECTOR=y 时，案例负载出连 10.0.2.2:8331，
由本进程负责"收下→原样发回"，让 guest 侧的微基准获得与自环等价的
乒乓语义（SLIRP 把 guest→10.0.2.2 的 TCP 落到宿主机 loopback 同端口）。

用法：
    python3 tools/reflector.py [port]      # 缺省 8331

行为：
- 每条连接独立线程，全双工 echo，直到对端关闭。
- 周期打印每连接累计回显字节（ stderr），便于确认"零字节黑洞"故障。
"""
import socket
import sys
import threading
import time


def pump(conn: socket.socket, addr):
    total = 0
    t0 = time.time()
    try:
        while True:
            data = conn.recv(65536)
            if not data:
                break
            conn.sendall(data)
            total += len(data)
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass
        print(f"[reflector] {addr} closed: echoed {total} bytes "
              f"in {time.time() - t0:.1f}s", file=sys.stderr)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8331
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(4)
    print(f"[reflector] listening on 0.0.0.0:{port} (echo mode)", file=sys.stderr)
    while True:
        conn, addr = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print(f"[reflector] accepted {addr}", file=sys.stderr)
        threading.Thread(target=pump, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    main()
