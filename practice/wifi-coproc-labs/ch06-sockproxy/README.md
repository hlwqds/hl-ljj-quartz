# ch06-sockproxy —— socket 代理 RPC + ws\_\* API 全链路仿真

[[ch06-socket-proxy|第六章：socket 代理]] 的实现与验收：**sockproxy.c** 里一半是宿主侧
`ws_*` API（socket/connect/send/recv/close/dns，同步演示模型），另一半是假 S3 服务
（socket 表 + echo 数据行为 + 错误注入 + 水位记账），两半通过**内存回环传输层**
（ch03 帧层 + ch05 TLV，一字不差地完整打包/解析）相连——真机点亮时只替换传输层，
协议零改动。

## 测试矩阵（8 项全 PASS，见 run.log）

- 生命周期：sid 分配递增、connect、echo 往返、close 后复用；
- 错误映射：注入拒绝端口，应用层状态码跨河还原为负返回值；
- 1 MiB echo：4600B 批量 × 自动分帧重组，双向 SHA-1 一致（对账哈希
  `2a3ff199…`，与 p2p/vpn-labs 同款验收习惯）；
- 背压可观测：持续消费下 S3 侧瞬时水位峰值 4600 B ≤ 高水位门限 8192 B。

## 编译运行

```bash
zig cc -o test test.c sockproxy.c control.c cobs.c crc32.c framing.c sha1.c
./test
```

排错实录（宿主缓冲容量、水位公式的消费量口径、宏常量漏网）见 run.log——
三条都是背压与观测机制本身的现成教案。
