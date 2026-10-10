# 手写 VPN 实验室 · 套件公约（VPN LABS SPEC）

本文件是 `practice/vpn-labs/` 套件全部工程的实现契约，配套系列 [[diy-vpn|手写 VPN]]。

## 1. 定位与约定

- **定位**：把《手写 VPN》系列的正文拆成**可编译运行的最小实现**——明文隧道、
  流加密、安全信封、密钥交换、TUN 版 mini-VPN，一章一工程、工程间零件互相复用
  （sha1/sha256/hmac/chacha20 源文件按需拷贝进各工程，保证代码浏览页单工程自洽）。
- 技术栈：**C11 + BSD socket / C 标准库，零第三方依赖**。编译器不限：`zig cc`
  （自带 clang，Windows 上零安装）/ gcc / clang 皆可。与 [[diy-vpn|系列]]同款。
- 目录：`practice/vpn-labs/chNN-slug/`（NN 对应系列章节号）。
- 每工程必备：源码、`README.md`（中文，含拓扑与复现命令、反向 wikilink）、
  `run.log`（真实运行留存）。
- 端口号段：**13000–13199**（避开 lwip-examples 8200–8299 与 p2p-labs 12000–12199）。

## 2. 诚实性规则

- 本机可测的（ch02/04/05/06）全部真实运行留档，含失败与攻击注入；
- ch07（TUN）面向 Linux 真机，本仓环境无 Linux——以
  `zig cc --target x86_64-linux` **交叉编译验证**入库，运行输出待真机回填
  （同 [[embedded-basics|嵌入式硬件基础]]的"无板先行版"惯例）；
- 手写密码学一律用官方测试向量验收（RFC 8439 / RFC 2104 / FIPS 180-4），
  并附交叉验证（Python 标准库对拍），不靠"看起来随机"。

## 3. 各工程一览

| 工程                | 章  | 验证的机制                                       |
| ------------------- | --- | ------------------------------------------------ |
| ch02-udp-relay      | 2   | 帧封装、UDP 中继会话表、select 多路复用          |
| ch04-chacha20       | 4   | XOR 两种死法演示、RFC 8439 ChaCha20、文件加解密  |
| ch05-secure-channel | 5   | HMAC-SHA256、EtM 安全信封、篡改/重放/乱序注入    |
| ch06-dh-exchange    | 6   | DH 协商、KDF 派生、中间人攻击演示                |
| ch07-minivpn        | 7   | TUN 读写 × 安全信封双端、keepalive（Linux 真机） |
