#!/usr/bin/env python3
"""S31 生产基线：practice/zig-esp32-s31 章节工程只读盘点。

本脚本只做目录元数据探测（Path.exists / is_file / is_dir），
不读取工程源码内容、不调用 zig/idf.py/esptool、不执行构建、测试或烧录。
默认盘点 ch01..ch28，输出 TSV 或 JSON，供基线门禁脚本消费。

退出码：
  0  盘点完成（默认不因缺章/缺标记而失败）
  1  --strict 且存在缺章或不完整章节
  2  参数错误或套件根目录不可读
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

CHAPTER_DIR_RE = re.compile(r"^ch(?P<num>\d{2})-(?P<slug>[a-z0-9]+(?:-[a-z0-9]+)*)$")
EXPECTED_CHAPTERS = tuple(range(1, 29))
DEFAULT_SUITE = Path("practice") / "zig-esp32-s31"

# (JSON/TSV 列名, 相对章节目录的路径, 期望类型)
MARKERS = (
    ("build_zig", "build.zig", "file"),
    ("readme", "README.md", "file"),
    ("src", "src", "dir"),
)

TSV_COLUMNS = ("chapter", "path", "present", "build.zig", "README.md", "src/", "complete")


def default_suite_root() -> Path:
    """仓库根为 inventory.py 的上三级：baseline/ -> s31-production/ -> tools/ -> repo。"""
    repo_root = Path(__file__).resolve().parents[3]
    return repo_root / DEFAULT_SUITE


def parse_chapter_selection(raw: str | None) -> tuple[int, ...]:
    """解析 '07,08,12' 或 'ch07,ch28'；空值表示全部 ch01..ch28。"""
    if raw is None or not raw.strip():
        return EXPECTED_CHAPTERS

    numbers: set[int] = set()
    for item in raw.split(","):
        token = item.strip()
        if not token:
            raise ValueError("章节列表包含空项")
        match = re.fullmatch(r"(?:ch)?(\d{1,2})", token, flags=re.IGNORECASE)
        if match is None:
            raise ValueError(f"无法识别的章节选择: {token!r}")
        number = int(match.group(1))
        if number not in EXPECTED_CHAPTERS:
            raise ValueError(f"章节号超出 ch01..ch28: {token!r}")
        numbers.add(number)
    return tuple(sorted(numbers))


def marker_value(chapter_dir: Path, relative: str, kind: str) -> bool:
    candidate = chapter_dir / relative
    return candidate.is_file() if kind == "file" else candidate.is_dir()


def collect_rows(suite_root: Path, numbers: tuple[int, ...]) -> tuple[list[dict], list[str]]:
    """返回 (行列表, 重复章节目录告警)。不读取文件内容。"""
    buckets: dict[int, list[Path]] = {}
    for entry in suite_root.iterdir():
        if not entry.is_dir():
            continue
        match = CHAPTER_DIR_RE.match(entry.name)
        if match is not None:
            buckets.setdefault(int(match.group("num")), []).append(entry)

    warnings: list[str] = []
    rows: list[dict] = []
    for number in numbers:
        candidates = sorted(buckets.get(number, ()), key=lambda path: path.name)
        if candidates:
            chapter_dir = candidates[0]
            if len(candidates) > 1:
                names = ", ".join(path.name for path in candidates[1:])
                warnings.append(f"ch{number:02d} 存在多个候选目录，已取 {chapter_dir.name}；忽略: {names}")
            row = {
                "chapter": chapter_dir.name,
                "path": chapter_dir.name,
                "present": True,
                "duplicates": [path.name for path in candidates[1:]],
            }
            for key, relative, kind in MARKERS:
                row[key] = marker_value(chapter_dir, relative, kind)
        else:
            row = {
                "chapter": f"ch{number:02d}-*",
                "path": None,
                "present": False,
                "duplicates": [],
            }
            for key, _relative, _kind in MARKERS:
                row[key] = False
            warnings.append(f"ch{number:02d} 目录不存在")

        missing = [relative for key, relative, _kind in MARKERS if not row[key]]
        row["complete"] = row["present"] and not missing
        row["missing"] = list(missing)
        rows.append(row)
    return rows, warnings


def summary_of(rows: list[dict]) -> dict:
    return {
        "expected": len(rows),
        "present": sum(1 for row in rows if row["present"]),
        "complete": sum(1 for row in rows if row["complete"]),
        "incomplete": [row["chapter"] for row in rows if not row["complete"]],
    }


def flag(value: bool) -> str:
    return "yes" if value else "no"


def write_tsv(rows: list[dict], *, header: bool) -> None:
    if header:
        print("\t".join(TSV_COLUMNS))
    for row in rows:
        print(
            "\t".join(
                (
                    row["chapter"],
                    row["path"] or "-",
                    flag(row["present"]),
                    flag(row["build_zig"]),
                    flag(row["readme"]),
                    flag(row["src"]),
                    flag(row["complete"]),
                )
            )
        )


def write_json(suite_root: Path, rows: list[dict]) -> None:
    document = {
        "schema": "s31-baseline-inventory/1",
        "read_only": True,
        "suite_root": str(suite_root),
        "chapters": rows,
        "summary": summary_of(rows),
    }
    json.dump(document, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="inventory.py",
        description=(
            "只读盘点 practice/zig-esp32-s31 章节工程：检查每个 chNN 目录是否存在，"
            "以及 build.zig、README.md、src/ 三个标记是否就位。"
            "不读取源码、不调用 zig/idf.py/esptool、不执行构建/测试/烧录。"
        ),
        epilog=(
            "示例:\n"
            "  python tools/s31-production/baseline/inventory.py\n"
            "  python tools/s31-production/baseline/inventory.py --format json\n"
            "  python tools/s31-production/baseline/inventory.py --chapters 07,08,12 --strict\n"
            "  python tools/s31-production/baseline/inventory.py --root practice/zig-esp32-s31 --no-header\n"
            "\n"
            "退出码: 0 完成；1 --strict 发现缺章/不完整；2 参数或根目录错误。"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--root",
        metavar="DIR",
        default=None,
        help="套件根目录（默认从本脚本位置推断 <repo>/practice/zig-esp32-s31）",
    )
    parser.add_argument(
        "--format",
        choices=("tsv", "json"),
        default="tsv",
        help="输出格式（默认 tsv）",
    )
    parser.add_argument(
        "--chapters",
        metavar="LIST",
        default=None,
        help="只盘点指定章节，逗号分隔，如 07,08,12 或 ch07,ch28（默认 ch01..ch28）",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="存在缺章或缺标记时以退出码 1 结束；默认只报告，不判失败",
    )
    parser.add_argument(
        "--no-header",
        action="store_true",
        help="TSV 不输出表头（JSON 模式下无效果）",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        numbers = parse_chapter_selection(args.chapters)
    except ValueError as exc:
        parser.error(str(exc))  # argparse 以退出码 2 结束

    suite_root = Path(args.root).expanduser() if args.root else default_suite_root()
    if not suite_root.is_dir():
        print(f"error: 套件根目录不存在或不是目录: {suite_root}", file=sys.stderr)
        return 2

    try:
        rows, warnings = collect_rows(suite_root, numbers)
    except OSError as exc:
        print(f"error: 无法读取套件根目录 {suite_root}: {exc}", file=sys.stderr)
        return 2

    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)

    if args.format == "json":
        write_json(suite_root, rows)
    else:
        write_tsv(rows, header=not args.no_header)

    summary = summary_of(rows)
    print(
        f"summary: expected={summary['expected']} present={summary['present']} "
        f"complete={summary['complete']} incomplete={len(summary['incomplete'])}",
        file=sys.stderr,
    )

    if args.strict and summary["incomplete"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
