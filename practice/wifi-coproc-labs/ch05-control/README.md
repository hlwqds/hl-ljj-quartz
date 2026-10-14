# ch05-control —— TLV 控制命令 + req_id 会话 + 扫描分片

[[ch05-control-protocol|第五章：控制通道]] 的实现与验收：**control.c**（TLV 编解码游标、
请求/应答拼装、扫描分片重组器），测试跑在**内存回环传输层**上——请求经 ch03 帧层
完整打包 → 假 S3 解析应答 → 喂回宿主解析，全链路（帧/COBS/CRC/TLV）一次过。

## 测试矩阵（7 项全 PASS，见 run.log）

- PING 全链回环：req_id/status/TLV 载荷无损；
- JOIN 参数：TLV 顺序无关、未知 type 跳过、重复 type 语义；
- TLV 溢出置位不截断（调用方换分片策略）；
- 扫描分片：乱序攒齐 + 重放片被拒；
- 越界 len 的 TLV 直接拒绝（线协议 bug 探测）。

## 编译运行

```bash
zig cc -o test test.c control.c cobs.c crc32.c framing.c   # Linux/macOS 同一行
./test
```

排错实录（字节序断言自己踩自己的纪律）见 run.log；四个协议源文件拷自
ch03-framing（套件公约：零件随工程走）。
