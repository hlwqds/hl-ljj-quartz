#!/usr/bin/env python3
"""ch19 控制通道客户端：一条连接发一条命令，回收全部应答。"""
import socket
import sys

HOST = "127.0.0.1"
PORT = 8023


def send_cmd(cmd: str, timeout: float = 30.0) -> str:
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    s.sendall(cmd.encode() + b"\n")
    chunks = []
    try:
        while True:
            data = s.recv(65536)
            if not data:
                break
            chunks.append(data.decode(errors="replace"))
            joined = "".join(chunks)
            if "$@@ BENCHDONE" in joined or "### ENDTASKTABLE" in joined:
                break
    except socket.timeout:
        pass
    finally:
        s.close()
    return "".join(chunks)


if __name__ == "__main__":
    print(send_cmd(" ".join(sys.argv[1:])))
