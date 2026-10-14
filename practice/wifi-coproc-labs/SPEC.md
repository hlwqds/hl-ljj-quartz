# WiFi 协处理器实验室 · 套件公约（WIFI-COPROC LABS SPEC）

本文件是 `practice/wifi-coproc-labs/` 套件全部工程的实现契约，配套系列
[[wifi-coproc|F429 × Korvo-1 WiFi 协处理器实战]]。

## 1. 定位与约定

- **定位**：把系列正文的协议层做成**可独立验证的最小实现**——帧协议（COBS+CRC32）、
  控制命令（TLV）、socket 代理（RPC + 背压），一层一工程；协议层与物理传输解耦
  （字节流接口），在**内存回环传输层**上真实运行留档，板级点亮时只替换传输层实现。
- 技术栈：**C11，零第三方依赖**。编译器：本机 `zig cc`（Zig 0.17 自带 clang）；
  F429 侧骨架以 `-target thumb-freestanding-eabihf -mcpu=cortex_m4` 交叉编译验证；
  S3 侧骨架对**桩 IDF 头**编译验证（API 形状与任务逻辑），真机编译待板。
- 目录：`practice/wifi-coproc-labs/chNN-slug/`；公共零件（cobs/crc32/framing）按
  p2p-labs 惯例**拷贝进各工程**，保证代码浏览页单工程自洽。
- 每工程必备：源码、`README.md`（含拓扑与复现命令、反向 wikilink）、`run.log`
  （真实运行留存）。

## 2. 诚实性规则

- 协议层三工程（ch03/05/06）全部本机真实运行留档，含故障注入路径；
- 板级骨架（ch02）标注验证边界：F429 侧交叉编译验证、S3 侧桩头编译验证，
  真机输出待板（「先成文后实跑」，同 [[embedded-basics|embedded-basics]] 无板先行版）；
- 手写算法一律官方向量验收（CRC32 的 `"123456789"` → `0xCBF43926` 等），
  并与 Python 标准库交叉对拍。

## 3. 各工程一览

| 工程              | 章  | 验证的机制                                      |
| ----------------- | --- | ----------------------------------------------- |
| ch02-spi-skeleton | 2   | SPI 交换状态机、DRDY 握手逻辑（两侧骨架，待板） |
| ch03-framing      | 3   | COBS 透明打包、CRC32、帧封装与流式解析          |
| ch05-control      | 5   | TLV 命令编解码、req_id 会话、扫描分片重组       |
| ch06-sockproxy    | 6   | socket 代理 RPC、ws\_\* API、背压与错误映射     |
