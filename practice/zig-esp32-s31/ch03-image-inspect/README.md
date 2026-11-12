# ch03 image-inspect：主机侧的镜像与分区表解析器

> 所属章节：[[ch03-boot-image-partition|第三章：启动链、镜像格式与分区]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

## 目的

这是一个**主机侧**的只读解析器：输入一个本地文件，把它当作 ESP 应用镜像或二进制分区表解析，
把每个字段的含义打印出来，并校验镜像自带的 XOR 校验和、可选 SHA256，以及分区表的 MD5。

它解决的问题是"读得懂 `esptool` 的输出"：`esptool image-info` 会给你一个字段列表，但那些数字
为什么是这些值、校验和覆盖了哪些字节、入口地址落在哪个地址空间，只有自己按格式算一遍才真正清楚。

工程**不接触硬件**：不开串口、不烧录、不读芯片，只读文件。因此它可以在没有板子的机器上反复运行，
也是后面 ch04 自己产出镜像时的第一道检查工具。

> [!warning] 验证状态
> **已与真机镜像对拍（2026-11-13）**：解析 ch02 产出的 186 832 B 镜像，5 段、checksum `0x20`、
> SHA256 `82f3d2cc…` 与 `esptool --chip esp32s31 image-info` 完全一致；分区表 `md5` 校验也通过。

## 文件表

| 路径           | 角色                                                     | 代码浏览                                                             |
| -------------- | -------------------------------------------------------- | -------------------------------------------------------------------- |
| `build.zig`    | 主机目标、`addExecutable`、`installArtifact`、`run` 步骤 | [查看](/static/code/#/zig-esp32-s31/ch03-image-inspect/build.zig)    |
| `src/main.zig` | 格式常量、镜像/分区表解析、校验、报表输出                | [查看](/static/code/#/zig-esp32-s31/ch03-image-inspect/src/main.zig) |
| `README.md`    | 本文件                                                   | [查看](/static/code/#/zig-esp32-s31/ch03-image-inspect/README.md)    |

没有 `build.zig.zon`（零依赖），没有 `run.log`（工具在主机侧跑，输出见 `../logs/` 与 BRINGUP）。

## 环境

| 工具 | 版本要求 | 说明                                               |
| ---- | -------- | -------------------------------------------------- |
| Zig  | 0.17.1   | 只用到 `std.fs` / `std.mem` / `std.crypto`；无依赖 |

```bash
zig version   # 期望 0.17.1
```

## 构建与运行

```bash
cd practice/zig-esp32-s31/ch03-image-inspect

zig build                       # 产物：zig-out/bin/s31-image-inspect
zig build run -- <file>         # 直接把参数传给工具
./zig-out/bin/s31-image-inspect <file>
```

`zig build run -- <file>` 里的 `--` 是 `zig build` 自己的分隔符：它之后的参数才会进 `b.args`，
再被 `run` 步骤追加到可执行文件后面。参数个数不等于 1 时打印用法并以 **2** 退出。

## 输入与判定

| 首字节      | 判定         | 解析内容                                                            |
| ----------- | ------------ | ------------------------------------------------------------------- |
| `0xE9`      | ESP 应用镜像 | 8 字节 common header、16 字节扩展头、各段头与段数据、校验和、SHA256 |
| `0xAA 0x50` | 二进制分区表 | 32 字节条目序列、类型/子类型、flags、MD5 尾块                       |
| 其它        | 不认识       | 打印原因，退出码 1                                                  |

典型输入来源（都需要先用 `esptool` 从 Flash 或构建产物里取出来）：

| 输入                    | 取法                                                                   |
| ----------------------- | ---------------------------------------------------------------------- |
| 应用镜像 `app.bin`      | `idf.py build` 的 `build/<project>.bin`，或 `esptool elf2image` 的产物 |
| 分区表 `partitions.bin` | `build/partition_table/partition-table.bin`                            |
| 从整片 dump 里切出的表  | `esptool --chip esp32s31 read-flash 0x8000 0xC00 partitions.bin`       |

工具只认"文件开头就是这段结构"的输入。整片 Flash dump（`0x0` 起、开头是 `0xFF`）不在支持范围，
先切出需要的区间再喂给它。

## 输出模式（字段示意图，不是实测日志）

下面是**字段清单与排版**，用 `<...>` 标出由输入决定的值。它不是任何一次真实运行的输出。

应用镜像：

```text
file        : <path>
format      : ESP application image (magic 0xE9)
file size   : <n> bytes (0x<n>)

[common header]
  magic            : 0xE9
  segment_count    : <1..16>
  flash_mode       : 0x<00..03> (<QIO|QOUT|DIO|DOUT>)
  flash_size_freq  : 0x<4F 之类的组合> (size <16MB>, freq <80MHz>)
  entry_addr       : 0x<xxxxxxxx> (<flash-mapped|SRAM|ROM|LP SRAM|other>)

[extended header]
  wp_pin           : 0x<xx> (disabled)
  pin drive        : clk=<d> q=<d> d=<d> cs=<d> hd=<d> wp=<d>
  chip_id          : <32> (<ESP32-S31>)
  min_rev          : 0x<xx> / v<d>.<d>
  max_rev          : v<d>.<d>
  hash_appended    : <0|1>

[segments]
  #   load addr     size      file off    region
  <i> 0x<xxxxxxxx>  0x<nnnnnn>  0x<nnnnnn>    <region>
  payload total    : <n> bytes

[checksum]
  offset           : 0x<n> (16-byte aligned)
  stored           : 0x<xx>
  computed (XOR)   : 0x<xx>
  result           : <OK|MISMATCH>

[sha256]
  offset           : 0x<n> (covers 0x<n> bytes)
  stored           : <64 hex chars>
  computed         : <64 hex chars>
  result           : <OK|MISMATCH>

verdict: <OK|FAILED>
```

没有追加摘要时，`[sha256]` 一节只打印 `appended : no`。

分区表：

```text
file        : <path>
format      : ESP partition table (magic 0xAA50)
file size   : <n> bytes (0x<n>)

[entries]
  #   label             type            subtype          offset      size        flags
  <i> <name, <=16>       <app|data|...>  <factory|nvs|...>  0x<nnnnnn>  0x<nnnnnn>  0x<xxxxxxxx>
  entries          : <n> (max 95)

[md5]
  offset           : 0x<n> (covers the <n> entry bytes)
  stored           : <32 hex chars>
  computed         : <32 hex chars>
  result           : <OK|MISMATCH>

[padding]
  bytes after table: <n> (0xFF padding: <yes|no>)

verdict: <OK|FAILED>
```

## 退出码与校验项

| 退出码 | 含义                                                          |
| ------ | ------------------------------------------------------------- |
| `0`    | 结构完整且所有校验通过                                        |
| `1`    | 结构非法，或校验和不匹配，或文件读不出来；原因已打印到 stderr |
| `2`    | 命令行参数不对（少给/多给文件路径）                           |

镜像模式的硬校验（任一不过 → 退出码 1）：

1. 首字节必须是 `0xE9`，段数在 1..16；
2. 第 9 字节是 `wp_pin`：`0xEE` 表示禁用，其他值是 GPIO 编号；扩展头没有独立 magic；
3. 扩展头保留的 4 字节非零只提示（不拒绝），`hash_appended` 只能是 0 或 1；
4. 每个段的长度必须是 4 的倍数，且段数据不能越过文件尾；
5. 段数据的 XOR（初值 `0xEF`）必须等于校验和字节；
6. 声明了追加摘要时，SHA256（覆盖到校验和字节为止）必须与末尾 32 字节一致。

分区表模式的硬校验：每条条目 32 字节且以 `0xAA 0x50` 开头；条目数不超过 95；
表内 MD5（尾块 `EB EB` + 14 个 `FF` + 16 字节摘要）必须与条目字节的 MD5 一致。

对齐与 16 MB 边界只是**提示**（`note:` 行），不改退出码：不同 IDF 版本对非 app 分区的
对齐要求不完全一样，把提示降级能让工具对历史分区表也保持可用。

## 与 `image-info` 对拍（待真机验证）

拿到真机产出的镜像后，按下面的顺序把两边字段逐项抄到一张表里：

```bash
# 1) 官方工具
esptool --chip esp32s31 image-info build/<project>.bin

# 2) 本工具
zig build run -- build/<project>.bin
```

需要逐项一致的字段：段数、入口地址、Flash 模式/容量/频率、扩展头的 `wp_pin`、`chip_id`、
最小/最大芯片修订、`hash_appended`，以及每个段的加载地址与长度。`image-info` 不打印 XOR 校验和，
所以那一行只能靠"两边都不报错 + 段数据逐字节相同"间接核对。

分区表则用 IDF 自带的解析器对拍（它会打印同样的条目与 MD5 结论）：

```bash
python $IDF_PATH/components/partition_table/gen_esp32part.py --verify \
  build/partition_table/partition-table.bin
```

> [!note] 对拍结果留档
> 真机跑通后，把两份输出的差异（如果有）记到本章的"排错"一节，而不是只在这里补一句"通过"。
> 差异本身就是最有价值的教学材料：它说明某个字段的语义在文档与实现之间被理解错了。

## 已知边界

- **只读、主机侧**：不烧录、不读芯片、不碰串口；没有真机也能跑。
- **不做 Flash 分区遍历**：不读整片 dump，不做 OTAdata/`otadata` 选择逻辑，那是 ch09 与 ch28 的事。
- **不做安全启动/加密镜像**：加密镜像的段数据经过硬件加密，静态解析只能看到密文；签名块也不解析。
- **不校验代码语义**：段能装进地址空间、能让 ROM 跳过去，不代表代码正确。
- **镜像长度以自身描述为准**：文件尾多出来的字节按 `[padding]` 报告，不当错误——从 Flash 里
  按扇区读出来的镜像天然带 `0xFF` 尾巴。
