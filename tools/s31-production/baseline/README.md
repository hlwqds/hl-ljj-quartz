# baseline：S31 生产基线门禁与只读盘点

本目录是 `tools/s31-production/` 的切片 A，只回答两个问题：

1. **生产化要过哪些门**：见 `matrix.md` 的构建矩阵、主机测试、ch07/ch08/ch12 缺陷回归、
   ch17 真链路、ch28 编译/上板、日志口径。
2. **章节工程是否就位**：`inventory.py` 只读盘点 `practice/zig-esp32-s31/ch01..ch28`
   是否存在，以及每个工程是否带 `build.zig`、`README.md`、`src/`。

> [!warning] 未验证边界
> 本切片**没有运行** `inventory.py`，**没有编译**任何 Zig/IDF 工程，**没有执行**
> `zig build test`、`elf2image`、`image-info`、`flash.sh`，**没有上板**，也**没有复核**
> `matrix.md` 引用的历史日志。`matrix.md` 中的“仓库记录”只是对已提交文档/日志的转述，
> 不构成本轮通过证据。`inventory.py` 只证明目录元数据，不证明任何工程可构建、可烧录、可运行。

## 文件

| 文件           | 作用                                             |
| -------------- | ------------------------------------------------ |
| `README.md`    | 本文件：用途、用法、边界                         |
| `matrix.md`    | 生产基线门禁表：每项含当前状态 / 通过判据 / 依赖 |
| `inventory.py` | 只读盘点脚本，输出 TSV 或 JSON；默认不执行构建   |

## `inventory.py`

### 要求

- Python **3.10+**，只用标准库（`argparse`/`json`/`pathlib`/`re`/`sys`）。
- 只调用 `Path.is_file()` / `Path.is_dir()` / `Path.iterdir()`，**不读取**工程源码内容，
  不导入 `subprocess`，不调用 `zig`、`idf.py`、`esptool`、`bash`。
- 只读：不创建、不修改、不删除任何文件。

### 用法

```bash
# 默认：从脚本位置推断 <repo>/practice/zig-esp32-s31，输出 TSV
python tools/s31-production/baseline/inventory.py

# JSON（含 summary 与每章 missing 列表）
python tools/s31-production/baseline/inventory.py --format json

# 只盘点三个缺陷回归章节，缺章/缺标记时退出码 1
python tools/s31-production/baseline/inventory.py --chapters 07,08,12 --strict

# 指定套件根目录；TSV 不要表头
python tools/s31-production/baseline/inventory.py --root practice/zig-esp32-s31 --no-header
```

`--help` 给出完整参数、示例与退出码：

```text
python tools/s31-production/baseline/inventory.py --help
```

### 输出

TSV 列（顺序固定）：

| 列          | 含义                                                 |
| ----------- | ---------------------------------------------------- |
| `chapter`   | 目录名，如 `ch07-interrupts-clic`；缺章时为 `chNN-*` |
| `path`      | 相对套件根目录的路径；缺章时为 `-`                   |
| `present`   | 章节目录是否存在（`yes`/`no`）                       |
| `build.zig` | 章节目录下是否存在 `build.zig` 文件                  |
| `README.md` | 章节目录下是否存在 `README.md` 文件                  |
| `src/`      | 章节目录下是否存在 `src/` 目录                       |
| `complete`  | 以上四项是否全部成立                                 |

JSON 顶层字段：

```text
schema       固定为 "s31-baseline-inventory/1"
read_only    固定为 true
suite_root   实际盘点的绝对路径
chapters     每章 {chapter,path,present,build_zig,readme,src,complete,missing,duplicates}
summary      {expected,present,complete,incomplete}
```

不存在的章节也会占一行（`present=no`），因此固定 28 行；`duplicates` 仅 JSON 输出，
出现多个同号目录时另在 stderr 告警并取字典序第一个。

无论 `--format` 选哪种，stdout 只含 TSV/JSON 本体；stderr 末尾另有一行
`summary: expected=... present=... complete=... incomplete=...`，缺章/重复目录告警也在
stderr。需要纯净数据流时只重定向 stdout。

### 退出码

| 码  | 含义                                      |
| --- | ----------------------------------------- |
| 0   | 盘点完成；默认不因缺章/缺标记失败         |
| 1   | 指定了 `--strict`，且存在缺章或不完整章节 |
| 2   | 参数错误，或套件根目录不存在/不可读       |

### 判据边界

`complete=yes` 只表示三个标记存在，**不表示**：

- `build.zig` 语法正确或目标串可编译；
- `README.md` 内容符合章节契约；
- `src/` 里有源码、源码可构建；
- 工程已上板、已产生真实 `run.log`。

这些必须走 `matrix.md` 的构建/测试/真机门禁，且要有命令、退出码与原始输出。

## `matrix.md` 怎么读

- “当前状态”分四类：**仓库记录**（历史文档声称，本轮未复核）、**未执行**、
  **未闭环**（有失败记录）、**不适用**。
- “通过判据”是可执行、可观察的条件；不得用“看起来正常”替代。
- “依赖”列出硬件、工具链版本、日志与外部步骤；缺依赖时该项保持未验证。
- 本轮**没有**把任何一行标成“通过”。历史记录中的 `All 10 tests passed`、
  `checks: passed=8 failed=0` 等字样只是引用，不能当作 baseline 切片的验收结果。

## 与其它切片的关系

- 共享契约见 `../SPEC.md`；本目录不修改 `content/`、`practice/`、`scripts/`、
  `quartz/` 或仓库根文件。
- `ota/`、`netmgr/`、`hil/` 的纯逻辑测试应接入 `matrix.md` 的 B1/B3 门禁；
  本切片不替它们实现或运行测试。
- 真机门禁（第 3–5 节）与 `hil/` 的 `--dry-run` 计划对接时，仍以真实日志为唯一证据。

## 已知边界与排障

- **默认根目录推断失败**：脚本按 `__file__` 上三级找仓库根；若目录被移动或单独拷贝，
  用 `--root` 显式指定 `practice/zig-esp32-s31`。
- **期望 ch01 也有 `build.zig`**：ch01 是板卡鉴定章节，按现行仓库实际只有 `README.md`，
  因此盘点结果会显示 `ch01` 不完整；这是契约事实，不是脚本缺陷。是否给 ch01 增加
  `build.zig`/`src/` 属于章节工程决策，本切片不改 `practice/`。
- **章节选择**：`--chapters` 只接受 `1..28`（可写 `07` 或 `ch07`），不接受范围语法。
- **符号链接**：`is_file()`/`is_dir()` 跟随符号链接；不额外解析链接目标。
- **编码**：JSON 以 UTF-8 输出、`ensure_ascii=False`；重定向到文件时由调用方决定换行。
