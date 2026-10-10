# ch06-dh-exchange —— Diffie-Hellman 协商 + 中间人演示

把 [[ch06-key-exchange|第六章：密钥交换]] 做成单文件实验：梅森素数 p = 2⁶¹−1 的
**原根现算验证**（对 p−1 的每个素因子 q 检查 g^((p−1)/q) ≠ 1，trial division 分解）、
128 位快速模幂、**正常协商**（两侧共享密钥相等 → KDF 双向分钥，直接对接 ch05 的
send_key/recv_key）与 **MITM 模式**（M 各与 A、B 会合一次，两条隧道全部可解——
两端毫无察觉，只有上帝视角的"密钥不等"露馅）。

## 编译运行

```bash
zig cc -o dh dh.c sha256.c     # Linux/macOS 同一行
./dh                           # 正常协商
./dh mitm                      # 中间人三视角
```

诚实性说明：演示群是 61 位玩具群（128 位整型即可承载），真实世界用 2048+ 位模群或
Curve25519（WireGuard 的选择）——数学同构，规模不同。完整输出与 MITM 配对用反的
排错记录见 `run.log`。
