# ch02-udp-relay —— 明文 UDP 中继隧道

把 [[ch02-udp-tunnel|第二章：明文隧道]] 的 N 造出来：**tclient**（本地 TCP 监听 → 帧封装
成 UDP 发中继）+ **relay**（会话表 + select 多路复用 + 30s 超时回收）。帧格式
`[type(1)][sid(4)][seq(4)][payload]`，type ∈ OPEN/OPENACK/DATA/CLOSE——seq 字段从
明文阶段就为 ch05 防重放留位。全程明文（教学点：抓包全裸），是 ch04/05 加密零件的
装配底座。

## 拓扑

```text
应用(curl) ──TCP──▶ tclient:13000 ──UDP 帧──▶ relay:13001 ──TCP──▶ 目标:8000
                    OPEN(host,port)/DATA/CLOSE          会话表 sid→TCP
```

## 编译

```bash
zig cc -o relay relay.c -lws2_32       # Linux/macOS 去掉 -lws2_32
zig cc -o tclient tclient.c -lws2_32
```

## 复现（本机三进程 + curl 验收）

```bash
python -m http.server 8000 --bind 127.0.0.1    # 终端 1：真实目标
./relay 13001                                  # 终端 2：中继
./tclient 13000 127.0.0.1:13001 127.0.0.1 8000 # 终端 3：隧道客户端
curl -s http://127.0.0.1:13000/ | head -4      # 终端 4：流量穿隧道，网页回来
```

真实跨网部署：tclient 与 relay 分处两机（或 relay 部署在公网服务器），目标参数换成
内网服务——这就是最朴素的"远程接入"。抓包 `udp.port==13001` 看 DATA 帧明文可读，
下一章实验（ch04）的动机就在这。

完整真实输出见 `run.log`（含两侧日志与字节对账）。
