#!/usr/bin/env python3
"""ch20 控制通道客户端：一条连接一条命令，读到 EOF。

用法：
  python3 tools/ch20ctl.py hello
  python3 tools/ch20ctl.py st
  python3 tools/ch20ctl.py restart 2 0     # recv_wait_timeout=2s lru=off
"""
import socket, sys

PORT = 8025


def main():
    parts = sys.argv[1:]
    if not parts:
        parts = ["hello"]
    line = " ".join(parts).encode()

    s = socket.create_connection(("127.0.0.1", PORT), timeout=15)
    s.sendall(line)
    buf = b""
    while True:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            print("!! ctrl reply timeout", file=sys.stderr)
            break
        if not chunk:
            break
        buf += chunk
    print(buf.decode(errors="replace"), end="")
    s.close()


if __name__ == "__main__":
    main()
