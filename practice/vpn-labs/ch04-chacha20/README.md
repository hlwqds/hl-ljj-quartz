# ch04-chacha20 —— XOR 破解演示 + 手写 ChaCha20（RFC 8439）

把 [[ch04-stream-cipher|第四章：从 XOR 到 ChaCha20]] 变成可运行实验：**xor_demo.c**
现场演示 XOR 的两种死法（密钥复用两条密文互消、已知 IP 头还原密钥流）；**chacha20.c**
是 RFC 8439 教科书实现（4×4 状态、quarter round、20 轮、末态加回），**chachatest.c**
拿官方测试向量逐字节验收，外加 1MiB 回环与文件加解密 CLI。

## 验证链（run.log 里的三重对账）

手写 C 实现 == RFC 8439 §2.3.2 官方向量 == pycryptodome 参考实现
（key=`00..1f`，nonce=`000000090000004a00000000`，counter=1 → `10f1e7e4…`）。
手写密码学的第一纪律：对官方向量验收，不靠"看起来随机"。

## 编译运行

```bash
zig cc -o chachatest chachatest.c chacha20.c     # Linux/macOS 同一行（无平台依赖）
zig cc -o xor_demo xor_demo.c
./xor_demo                                    # 两种 XOR 死法
./chachatest                                  # RFC 向量 + 1MiB 回环
./chachatest enc in.bin out.bin <64位hex钥> <24位hex nonce>   # 文件加密
./chachatest dec out.bin back.bin <同 key+nonce>             # 解密（sha1sum 对账）
```

完整真实输出见 `run.log`（含文件加解密 sha1 对账一致）。
