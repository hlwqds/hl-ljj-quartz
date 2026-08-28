#!/usr/bin/env python3
"""lwIP ch15 raw-vs-socket TCP bench.

Subcommands:
  rtt      --port P --size B --n N --rounds R [--label L]   ping-pong latency
  tput     --port P --size B --blocks N --window W --rounds R [--label L]
                                                    pipelined echo throughput
  dualrtt  --port P --dur S --ivl MS                             two concurrent conns
  eofcycle --port P --cycles N                                   FIN half-close cycles
  abrt     --port P                                              ABRT marker probe
  floodtp  --port P --dur S                                      sustained stream tput
  ctrl     --cmd "busy:200|st|leak:on|leak:off|xt|xtw"           control UDP cmd

payload = b'C15' + kind(1) + seq u32BE + filler, echo must match byte-exact.
"""
import argparse, socket, struct, sys, threading, time

HOST = "127.0.0.1"
CTRL_PORT = 8027
MAGIC = b"C15"


def mk(kind, seq, size):
    k = kind[0] if isinstance(kind, (bytes, bytearray)) else kind
    return MAGIC + bytes([k]) + struct.pack(">I", seq) + b"\xa5" * (size - len(MAGIC) - 5)


def check(buf):
    return buf[:3] == MAGIC


def open_conn(port):
    s = socket.create_connection((HOST, port), timeout=10)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def pctl(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * (len(xs) - 1)))] if xs else 0


# ---------------------------------------------------------------- rtt
def rtt_round(port, size, n, label):
    s = open_conn(port)
    samples = []
    ok = 0
    for i in range(n):
        pay = mk(b"L", i, size)
        t0 = time.monotonic_ns()
        try:
            s.sendall(pay)
            got = recv_exact(s, size)
            t1 = time.monotonic_ns()
        except OSError:
            break
        if got == pay:
            ok += 1
            samples.append((t1 - t0) // 1000)
    s.close()
    emit_lat(label, port, size, n, ok, samples)


def recv_exact(s, size):
    buf = b""
    while len(buf) < size:
        chunk = s.recv(size - len(buf))
        if not chunk:
            raise OSError("eof")
        buf += chunk
    return buf


def emit_lat(label, port, size, n, ok, samples):
    us = [int(x) for x in samples]
    avg = sum(us) / len(us) if us else 0
    print(f"LAT label={label} port={port} size={size} n={n} ok={ok} "
          f"avg_us={avg:.1f} med_us={pctl(us, .5)} min_us={min(us) if us else 0} "
          f"max_us={max(us) if us else 0} p95_us={pctl(us, .95)}", flush=True)


# ---------------------------------------------------------------- tput
def tput_round(port, size, blocks, window, label):
    s = open_conn(port)
    inflight = {}
    sent = echoed = 0
    t0 = time.monotonic()
    seq = 0
    tail_missing = 0
    while echoed < blocks and time.monotonic() - t0 < 30:
        while sent < blocks and len(inflight) < window:
            pay = mk(b"T", seq, size)
            s.sendall(pay)
            inflight[seq] = pay
            seq += 1
            sent += 1
        # drain as much as available non-blocking-ish
        s.settimeout(2.0)
        try:
            got = recv_exact(s, size)
        except socket.timeout:
            break
        except OSError:
            break
        if check(got):
            rseq = struct.unpack(">I", got[4:8])[0]
            if rseq in inflight:
                del inflight[rseq]
                echoed += 1
    elapsed = time.monotonic() - t0
    tail_missing = blocks - echoed
    mbit = echoed * size * 8 / elapsed / 1e6
    print(f"TPUT label={label} port={port} size={size} window={window} blocks={blocks} "
          f"echoed={echoed} missing_tail={tail_missing} secs={elapsed:.3f} mbit={mbit:.2f}",
          flush=True)
    s.close()


# ------------------------------------------------------------- dualrtt
dual_stop = False


def dual_worker(name, port, ivl_ms, out):
    global dual_stop
    try:
        s = open_conn(port)
    except OSError as e:
        print(f"DRTT-FATAL conn {name}: {e}", flush=True)
        return
    i = 0
    while not dual_stop:
        pay = mk(b"D", i, 64)
        t0 = time.monotonic()
        try:
            s.sendall(pay)
            got = recv_exact(s, 64)
        except OSError as e:
            out.append((name, time.time(), -1))
            print(f"DRTT-ERR id={name} idx={i} err={e}", flush=True)
            break
        t1 = time.monotonic()
        if got != pay:
            print(f"DRTT-CORRUPT id={name} idx={i}", flush=True)
            break
        us = (t1 - t0) * 1e6
        ts = time.monotonic()
        out.append((name, ts, us))
        print(f"DRTT id={name} idx={i} mono={ts:.3f} us={us:.1f}", flush=True)
        i += 1
        time.sleep(ivl_ms / 1000.0)
    s.close()


def dualrtt(port, dur, ivl):
    global dual_stop, dual_stop_flag
    out = []
    dual_stop = False
    ta = threading.Thread(target=dual_worker, args=("A", port, ivl, out), daemon=True)
    tb = threading.Thread(target=dual_worker, args=("B", port, ivl, out), daemon=True)
    t_start = time.monotonic()
    ta.start(); tb.start()
    time.sleep(dur)
    dual_stop = True
    ta.join(timeout=5); tb.join(timeout=5)
    # per-second summary
    buckets = {}
    base = {}
    for name, ts, us in out:
        if us < 0:
            continue
        sec = int(ts - t_start)
        buckets.setdefault(sec, {}).setdefault(name, []).append(us)
    # baseline: median of second 0..1 across both
    allbase = [us for name, ts, us in out if us >= 0 and ts - t_start < 1.5]
    bmed = pctl([int(x) for x in allbase], .5) or 1
    print(f"DRTT-SUM baseline_med_us={bmed}", flush=True)
    for sec in sorted(buckets):
        line = f"DRTT-SEC sec={sec}"
        for name in ("A", "B"):
            v = buckets[sec].get(name)
            if v:
                vi = [int(x) for x in v]
                line += f" {name}(med={pctl(vi,.5)},max={max(vi)},n={len(vi)})"
        print(line, flush=True)


# ------------------------------------------------------------- eofcycle / abrt
def eofcycle(port, cycles):
    for i in range(cycles):
        try:
            s = open_conn(port)
            s.sendall(mk(b"E", i, 128))          # 一段普通数据
            s.shutdown(socket.SHUT_WR)           # FIN：raw 服务端收到 p==NULL EOF
            try:
                while True:
                    d = s.recv(4096)
                    if not d:
                        break                    # 服务端 close 完成（正确路径）
            except ConnectionResetError:
                pass
            s.close()
        except OSError as e:
            print(f"EOFCYCLE i={i} oserr={e}")
        time.sleep(0.4)
    print(f"EOFCYCLE done cycles={cycles}", flush=True)


def abrt_probe(port):
    try:
        s = open_conn(port)
        s.sendall(b"ABRT" + b"\x00" * 60)       # 触发服务端 tcp_abort()+return ERR_ABRT
        time.sleep(0.3)
        r = s.recv(1024)
        if not r:
            print("ABRTPROBE server closed orderly")
        else:
            print(f"ABRTPROBE unexpected data {r[:20]!r}")
    except ConnectionResetError as e:
        print(f"ABRTPROBE reset by peer ({e}) -> RST seen，符合 abort 预期", flush=True)
    except OSError as e:
        print(f"ABRTPROBE oserr={e}", flush=True)
    finally:
        try:
            s.close()
        except Exception:
            pass


# ------------------------------------------------------------- floodtp
flood_stop = False


def floodtp(port, dur):
    """定速之外的尽力流：发送线程全速写，主循环收回显并每秒报速率。"""
    global flood_stop
    flood_stop = False
    s = open_conn(port)
    size = 1200

    err_box = []

    def sender():
        i = 0
        while not flood_stop:
            try:
                s.sendall(mk(b"F", i, size))
                i += 1
            except OSError as e:
                err_box.append(str(e))
                break

    th = threading.Thread(target=sender, daemon=True)
    t0 = time.monotonic()
    total = 0
    last_report = t0
    sent_at_start = None
    th.start()
    while time.monotonic() - t0 < dur:
        s.settimeout(0.5)
        d = b""
        try:
            d = s.recv(65536)
        except socket.timeout:
            pass
        except OSError as e:
            err_box.append(str(e))
            break
        total += len(d)
        now = time.monotonic()
        if now - last_report >= 1.0:
            mb = total * 8 / (now - t0) / 1e6
            print(f"FLOODTP t={now - t0:.1f}s rx_bytes={total} "
                  f"rate_mbit={mb:.2f}", flush=True)
            last_report = now
    flood_stop = True
    try:
        s.close()
    except Exception:
        pass
    th.join(timeout=3)
    print(f"FLOODTP-DONE dur={dur} rx={total} errs={err_box or 'none'}", flush=True)


# ------------------------------------------------------------- ctrl
def ctrl_cmd(payload):
    a = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    a.settimeout(3)
    a.sendto(payload.encode(), (HOST, CTRL_PORT))
    try:
        data, _ = a.recvfrom(512)
        print(f"CTRL '{payload}' -> {data.decode(errors='replace')}", flush=True)
    except socket.timeout:
        print(f"CTRL '{payload}' -> no ack (check guest log)", flush=True)
    a.close()


# ------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("rtt");      p.add_argument("--port", type=int)
    p.add_argument("--size", type=int, default=64)
    p.add_argument("--n", type=int, default=400)
    p.add_argument("--rounds", type=int, default=3)
    p.add_argument("--label", default="x")

    p = sub.add_parser("tput");     p.add_argument("--port", type=int)
    p.add_argument("--size", type=int, default=1200)
    p.add_argument("--blocks", type=int, default=1500)
    p.add_argument("--window", type=int, default=16)
    p.add_argument("--rounds", type=int, default=3)
    p.add_argument("--label", default="x")

    p = sub.add_parser("dualrtt");  p.add_argument("--port", type=int)
    p.add_argument("--dur", type=float, default=10)
    p.add_argument("--ivl", type=float, default=50)

    p = sub.add_parser("eofcycle"); p.add_argument("--port", type=int)
    p.add_argument("--cycles", type=int, default=3)

    p = sub.add_parser("abrt");     p.add_argument("--port", type=int)

    p = sub.add_parser("floodtp");  p.add_argument("--port", type=int)
    p.add_argument("--dur", type=float, default=8)

    p = sub.add_parser("ctrl");     p.add_argument("--send", required=True)

    a = ap.parse_args()
    if a.cmd == "rtt":
        for r in range(a.rounds):
            rtt_round(a.port, a.size, a.n, f"{a.label}_r{r+1}")
            time.sleep(0.5)
    elif a.cmd == "tput":
        for r in range(a.rounds):
            tput_round(a.port, a.size, a.blocks, a.window, f"{a.label}_r{r+1}")
            time.sleep(1)
    elif a.cmd == "dualrtt":
        dualrtt(a.port, a.dur, a.ivl)
    elif a.cmd == "eofcycle":
        eofcycle(a.port, a.cycles)
    elif a.cmd == "abrt":
        abrt_probe(a.port)
    elif a.cmd == "floodtp":
        floodtp(a.port, a.dur)
    elif a.cmd == "ctrl":
        ctrl_cmd(a.send)


if __name__ == "__main__":
    main()
