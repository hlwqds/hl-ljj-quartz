#!/usr/bin/env python3
"""统一测试运行器：发现 t*.py、逐项执行、汇总、JSON 落盘。

契约：每个 tNN_*.py 模块导出 TESTS = [(tid, name, fn), ...]，
fn(ctx) -> (ok: bool, detail: str)。runner 对每个 fn：
- 捕获一切异常（含 KeyboardInterrupt 以外的 BaseException 之外的 Exception）
- 无全局退出，单项挂死靠 fn 内部的网络超时 + subprocess 包 TimeoutExpired
- 结果按序落 selftest.json，退出码 = FAIL 数（全绿为 0）
"""

import importlib
import json
import os
import pkgutil
import sys
import time

import ctx

PKG = os.path.dirname(os.path.abspath(__file__))


def load_tests():
    """按模块名排序发现 t*.py，聚合 TESTS 列表。"""
    tests = []
    for m in pkgutil.iter_modules([PKG]):
        if not m.name.startswith("t") or m.name[1].isdigit() is False:
            continue
        mod = importlib.import_module(m.name)
        for tid, name, fn in getattr(mod, "TESTS", []):
            tests.append((tid, name, fn))
    return tests


def run(tests, host, password, outdir):
    os.makedirs(outdir, exist_ok=True)
    venv_py = ctx.find_python()
    c = {"host": host, "password": password, "venv": venv_py, "outdir": outdir}
    results = []
    print(f"\n{'=' * 68}\n  ONVIF Labs 统一自测  host={host}  venv={venv_py or 'MISSING'}"
          f"\n{'=' * 68}")
    for tid, name, fn in tests:
        t0 = time.time()
        try:
            ok, detail = fn(c)
        except Exception as e:  # 任何抛穿都算该测试 FAIL，绝不中断整轮
            ok, detail = False, f"EXC {type(e).__name__}: {e}"
        dt = time.time() - t0
        mark = "✅ PASS" if ok else "❌ FAIL"
        print(f"  {mark}  {tid} {name}  [{dt:.1f}s]" + (f"  {detail}" if detail else ""),
              flush=True)
        results.append({"id": tid, "name": name, "pass": ok, "detail": detail,
                        "seconds": round(dt, 1)})
    n_pass = sum(1 for r in results if r["pass"])
    print(f"\n{'=' * 68}\n  RESULT: {n_pass}/{len(results)} PASS\n{'=' * 68}")
    for r in results:
        print(f"  {'✅' if r['pass'] else '❌'} {r['id']} {r['name']}"
              + (f"  — {r['detail']}" if r["detail"] and not r["pass"] else ""))
    out = {"host": host, "python": venv_py, "ts": time.strftime("%F %T"),
           "pass": n_pass, "total": len(results), "results": results}
    path = os.path.join(outdir, "selftest.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    print(f"  证据: {path}")
    return 1 if n_pass < len(results) else 0


def main():
    import argparse
    ap = argparse.ArgumentParser(description="ONVIF Labs 统一自测")
    ap.add_argument("--host", required=True, help="板子 IP")
    ap.add_argument("--password", default=None,
                    help="ONVIF 口令（默认读 lab06 main/onvif_secrets.h）")
    ap.add_argument("--outdir", default=os.path.join(PKG, "runs"))
    args = ap.parse_args()
    pw = args.password or ctx.password_from_secrets()
    if not pw:
        print("FATAL: 无口令（--password 或 onvif_secrets.h）", file=sys.stderr)
        return 2
    sys.path.insert(0, PKG)
    return run(load_tests(), args.host, pw, args.outdir)


if __name__ == "__main__":
    raise SystemExit(main())
