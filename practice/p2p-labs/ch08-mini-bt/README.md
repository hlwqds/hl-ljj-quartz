# ch08-mini-bt —— bencode · HTTP tracker · peer wire protocol 最小闭环

把 [[ch08-bittorrent|第八章：BitTorrent——分片、激励与去中心化]] 的核心链路做成真实
可跑的四进程闭环：**maketorrent.c**（造种：bencode 规范形式 + 逐片 SHA-1 +
infohash=SHA1(bencode(info))）、**tracker.c**（HTTP announce 点名：info_hash/peer_id/
left 参数解析、URL 解码、bencode 响应——只搬元数据）、**bt.c**（做种/取种：68 字节
握手、bitfield、interested/unchoke、request/piece 两级分片传输、16KiB 块 × 8 深度
流水线、**逐片 SHA-1 验收**）、底座是自带的 **bencode.c** 与 ch02 同款 **sha1.c**。

## 拓扑

```text
                ①announce(info_hash,peer_id,left)          ②peer 列表(bencode)
  leecher ───────────────────────────────────▶ tracker :12080 ─────────────▶ leecher
     │                                                                          │
     └────────── ③TCP 握手(19+协议名+保留+infohash+peer_id) ──▶ seeder :12101 ──┘
                 ④bitfield → interested → unchoke → request/piece×N（逐片 SHA-1 验收）
```

## 编译

```bash
zig cc -o maketorrent maketorrent.c bencode.c sha1.c -lws2_32   # Linux/macOS 去 -lws2_32
zig cc -o tracker tracker.c bencode.c -lws2_32
zig cc -o bt bt.c bencode.c sha1.c -lws2_32
```

## 复现（本机四进程，四个终端）

```bash
python -c "import os; open('demo.bin','wb').write(os.urandom(300_000))"   # 造随机文件
./maketorrent demo.bin http://127.0.0.1:12080/announce demo.torrent 32768
./tracker 12080                       # 终端 1
./bt seed demo.torrent demo.bin 12101 # 终端 2（做种者）
./bt get demo.torrent demo.out        # 终端 3（取种者）
sha1sum demo.bin demo.out             # 两行必须一致
```

## 刻意砍掉的（ch08 正文讲过、单 peer 场景无从体现）

稀缺优先/endgame（单 peer 无所谓稀缺）、choke 博弈（tit-for-tat 需要多 peer 竞争
上传位）、DHT/magnet（ch07 已单独实验）。多 leecher 抢种实验可作为进阶练习：
起两个 get，观察 tracker 的 peers 表互含。

完整真实输出见 `run.log`（含三次翻车实录：消息体重复拼 ID、同秒同 peer_id、
块长 off-by-one——第三条正是 piece 级 SHA-1 验收当场报警的价值演示）。
