#!/usr/bin/env python3
"""ch21 桥侧数据分析：按 (topic, tag) 分组——tag 区分固件阶段，规避 seq 复用假象。"""
import json, sys, collections, statistics

path = sys.argv[1] if len(sys.argv) > 1 else "run/bridge.jsonl"
rows = [json.loads(l) for l in open(path)]

def key(r):          # 阶段隔离键：同一编号序列只在本阶段内比较
    return (r["topic"], r["tag"])

groups = collections.defaultdict(list)
for r in rows:
    groups[key(r)].append(r)

print(f"total arrivals: {len(rows)}\n")
hdr = f"{'topic':22s} {'tag':10s} {'n':>4s} {'uniq':>5s} {'missing':>7s} {'dupC':>4s} {'dupGapMed(ms)':>13s}"
print(hdr); print("-" * len(hdr))

EXPECT = {"lossyq0": 200, "lossyq1": 200, "burstq0": 200, "burstq1": 200,
          "rttq0": 50, "rttq1": 50, "offline": None}
summary = {}
for k, rs in sorted(groups.items()):
    idx = collections.defaultdict(list)
    for r in rs:
        if r["seq"] >= 0:
            idx[r["seq"]].append(r["ts_ns"])
    uniq = len(idx)
    gaps = []
    for s, ts in idx.items():
        tss = sorted(ts)
        gaps += [(b - a) / 1e6 for a, b in zip(tss, tss[1:])]
    exp = EXPECT.get(k[1])
    miss = (exp - uniq) if exp else "-"
    med = f"{statistics.median(gaps):.0f}" if gaps else "-"
    print(f"{k[0]:22s} {k[1]:10s} {len(rs):4d} {uniq:5d} {str(miss):>7s} {len(gaps):4d} {med:>13s}")
    span = (max(r['ts_ns'] for r in rs) - min(r['ts_ns'] for r in rs)) / 1e6 if len(rs) > 1 else 0
    summary[k[1]] = dict(topic=k[0], n=len(rs), uniq=uniq, dups=len(gaps), span=span)

# offline 到达剖面：以首条为原点，50ms 一桶
off = sorted([r for r in rows if r["tag"] == "offline"], key=lambda r: r["ts_ns"])
if off:
    t0 = off[0]["ts_ns"]
    bins = collections.Counter(int((r["ts_ns"] - t0) / 5e7 * 1000) for r in off)
    print("\noffline drain profile (seq-first@0ms, each bin=50ms):")
    line = " ".join(f"{k*50}:{v}" for k, v in sorted(bins.items()))
    print(" ", line[:300])
    print(f" offline span total: {(off[-1]['ts_ns']-t0)/1e6:.0f} ms for {sum(bins.values())} msgs")
