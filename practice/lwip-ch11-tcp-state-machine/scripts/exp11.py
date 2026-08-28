#!/usr/bin/env python3
"""
lwIP 深度解析（十一）实验驱动脚本（主机侧）。

用法：
  python3 exp11.py --phase a_active | a_passive | b | c | d
  python3 exp11.py --role victim-child   # 仅内部使用：持有受害连接的子进程

约定：
  演示服务器：hostfwd tcp::8014-:8814   -> 主机 127.0.0.1:8014
  控制通道  ：hostfwd tcp::9014-:8813   -> 主机 127.0.0.1:9014
  实验 b 出向目标：guest -> 10.0.2.2:<sink>，落在宿主机回环同端口（SLIRP 特性）
"""
import argparse
import os
import signal
import socket
import sys
import threading
import time

CTRL_ADDR = ("127.0.0.1", 9014)
DEMO_ADDR = ("127.0.0.1", 8014)


def ctrl(cmd, timeout=15):
    s = socket.create_connection(CTRL_ADDR, timeout=timeout)
    s.sendall((cmd + "\n").encode())
    time.sleep(0.08)
    s.settimeout(3)
    try:
        data = s.recv(200)
    except OSError:
        data = b""
    s.close()
    return data.decode(errors="replace").strip()


def wait_ctrl(deadline_s=90):
    t0 = time.time()
    last = None
    while time.time() - t0 < deadline_s:
        try:
            return ctrl("STAT")
        except OSError as e:
            last = e
            time.sleep(0.7)
    raise RuntimeError(f"ctrl channel unreachable: {last}")


def demo_connect(timeout=15):
    return socket.create_connection(DEMO_ADDR, timeout=timeout)


def echo_round(s, payload, expect_echo=True):
    s.sendall(payload)
    got = b""
    if expect_echo:
        while len(got) < len(payload):
            chunk = s.recv(len(payload) - len(got))
            if not chunk:
                break
            got += chunk
    return got


def run_a(mode_name, rounds=3):
    """主动/被动关闭对照。guest 端状态序列由串口日志中的 PCBD 行呈现。"""
    print(f"[phase-a:{mode_name}] ctrl={ctrl('MODE ' + mode_name)}")
    for i in range(rounds):
        tag = f"{'A' if mode_name == 'ACTIVE' else 'P'}{i}"
        if mode_name == "PASSIVE":
            s = demo_connect()
            echo_round(s, f"PAYLOAD-{tag}-x16.".encode())
            s.shutdown(socket.SHUT_WR)          # 半关闭：FIN 先行，数据通道已尽
            s.settimeout(6)
            tail = b""
            try:
                while True:
                    c = s.recv(256)
                    if not c:
                        break
                    tail += c
            except OSError:
                pass
            s.close()
            print(f"[phase-a:{mode_name}] conn#{i} done tail={tail[:40]!r}")
        else:
            s = demo_connect()
            s.sendall(f"GO-{tag}\n".encode())   # 触发服务器立即 greeting + FIN
            s.settimeout(6)
            greet = s.recv(64)
            try:
                fin = s.recv(64)                # 应当立刻读到 EOF（服务器半关闭）
            except OSError:
                fin = b"<timeout>"
            s.close()
            print(f"[phase-a:{mode_name}] conn#{i} greet={greet.strip()!r} eof={fin!r}")
        time.sleep(1.2)
    print(f"[phase-a:{mode_name}] all {rounds} rounds done")


def sink_server(port, n_expected, done_evt):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(32)
    print(f"[phase-b] sink listening on 127.0.0.1:{port}", flush=True)
    seen = 0
    srv.settimeout(2)
    while not done_evt.is_set():
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        conn.settimeout(5)
        try:
            req = conn.recv(64)
            conn.sendall(b"ACK:" + req)         # 回包后不主动关，由 guest 先关
        except OSError:
            pass
        finally:
            conn.close()
            seen += 1
            print(f"[phase-b] sink served #{seen}: {req!r}", flush=True)
    print("[phase-b] sink exit", flush=True)


def run_b(n=60, port=8714):
    done = threading.Event()
    th = threading.Thread(target=sink_server, args=(port, n, done), daemon=True)
    th.start()
    time.sleep(0.3)
    print(f"[phase-b] trigger GW {n} conns -> 10.0.2.2:{port}")
    print(f"[phase-b] ctrl={ctrl(f'GW {n} {port}', timeout=20)}")
    # guest 侧 120ms/conn 节奏，注入约需 60*0.12 ≈ 8s；随后 TIME_WAIT 120s 才回收
    time.sleep(n * 0.12 + 8)
    print("[phase-b] injection finished; keep QEMU alive >=130s more to watch decay")


def victim_child(marker_fd):
    """子进程角色：与 guest 建连并保持，直到被父进程 SIGKILL（不发 FIN）。"""
    s = demo_connect(timeout=30)
    s.sendall(b"HELLO-VICTIM")
    s.settimeout(8)
    echo = s.recv(64)
    ready = (echo.startswith(b"HELLO-VICTIM")).to_bytes(1, "big")
    os.write(marker_fd, ready)
    while True:
        time.sleep(3600)                         # 既不发数据也不退出


def run_c():
    print(f"[phase-c] mode={ctrl('MODE PASSIVE')}")
    print(f"[phase-c] arm={ctrl('VICTARM')}")
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        try:
            victim_child(w)
        finally:
            os._exit(0)
    os.close(w)
    ok = os.read(r, 1)
    os.close(r)
    if ok != b"\x01":
        print("[phase-c] victim failed to establish; killing child")
        os.kill(pid, signal.SIGKILL)
        sys.exit(1)
    print(f"[phase-c] victim established (pid={pid}); firing inject")
    print(f"[phase-c] fire={ctrl('VICTFIRE')}")
    time.sleep(0.5)
    os.kill(pid, signal.SIGKILL)                 # 无 FIN、无 RST 的“断电式”消失
    _, status = os.waitpid(pid, 0)
    print(f"[phase-c] victim killed status={status}; "
          f"expect keepalive abort at ~idle 5s + 3 probes x 2s + timer tick")


def holder(idx, results, freeze_timeout):
    """实验 d 的半开连接持有者：connect 成功后长期静默持锁。"""
    try:
        s = demo_connect(timeout=freeze_timeout)
    except OSError as e:
        results[idx] = f"c_err({e.__class__.__name__})"
        return
    results[idx] = "c_ok"
    try:
        time.sleep(freeze_timeout)               # 连上后不说话
    finally:
        s.close()


def run_d(n_holders=8, hold_time=26):
    print(f"[phase-d] freeze={ctrl('FREEZE ON')}")
    results = {}
    ths = []
    for i in range(n_holders):
        t = threading.Thread(target=holder, args=(i, results, hold_time), daemon=True)
        t.start()
        time.sleep(0.35)
    # 等 20s 的 TCP_SYN_RCVD_TIMEOUT 自愈窗口过去
    for _ in range(int(hold_time)):
        time.sleep(1)
    print(f"[phase-d] holders={sorted(results.items(), key=lambda kv: kv[0])}")
    print(f"[phase-d] thaw={ctrl('FREEZE OFF')}")
    # 解冻后做一次正常往返，验证槽位已被 20s 定时器回收
    s = demo_connect(timeout=10)
    echo = echo_round(s, b"AFTER-THAW-x.")
    s.close()
    print(f"[phase-d] post-thaw roundtrip={'OK' if echo else 'FAIL'} ({echo!r})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", choices=["a_active", "a_passive", "b", "c", "d"])
    ap.add_argument("--role", choices=["victim-child"])
    ap.add_argument("--marker-fd", type=int, default=1)
    args = ap.parse_args()

    if args.role == "victim-child":
        victim_child(args.marker_fd)
        return

    stat = wait_ctrl()
    print(f"[boot] ctrl up: {stat}")
    print(f"[boot] STAT={ctrl('STAT')}")

    if args.phase == "a_active":
        run_a("ACTIVE")
    elif args.phase == "a_passive":
        run_a("PASSIVE")
    elif args.phase == "b":
        run_b()
    elif args.phase == "c":
        run_c()
    elif args.phase == "d":
        run_d()


if __name__ == "__main__":
    main()
