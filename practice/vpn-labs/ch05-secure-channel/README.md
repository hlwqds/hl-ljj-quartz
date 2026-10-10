# ch05-secure-channel —— HMAC 安全信封 + 篡改/重放注入

把 [[ch05-mac-replay|第五章：完整性与防重放]] 全部做成可运行实验：**sha256.c/hmac.c**
（手写，官方向量验收 + python 交叉对账）、**secure.c** 的 Encrypt-then-MAC 安全信封
（`[ctr(8)][ChaCha20 密文][HMAC-SHA256 标签]`，nonce 布局 = 方向魔数 + 帧计数器，
计数器被 MAC 覆盖）与 IPsec 同款**滑动窗口**（W=64 位图）。接收三步顺序即安全：
常量时间验签 → 查窗口 → 解密。

## 攻击注入矩阵（全部真实运行）

| 模式      | 场景                        | 预期与实测            |
| --------- | --------------------------- | --------------------- |
| `normal`  | 帧 1..5 顺序                | 全收 ✓                |
| `reorder` | 1,4,2,5,3 乱序（UDP 常态）  | 窗口内全部放行 ✓      |
| `replay`  | 重发已收的 ctr=3            | 位图命中，拒收 ❌     |
| `tamper`  | 翻转密文 1 比特             | MAC 当场爆炸 ❌       |
| `old`     | 冲到 ctr=200 后重发 ctr=100 | 窗口外历史包，拒收 ❌ |

## 编译运行

```bash
zig cc -o secure secure.c hmac.c sha256.c chacha20.c   # Linux/macOS 同一行
./secure && ./secure reorder && ./secure replay && ./secure tamper && ./secure old
```

完整输出与三段排错实录见 `run.log`（K[58] 手抄常数错、无符号回绕毁窗口、解密缓冲
忘补 NUL——第三个是安全代码里 `%s` 与密文边界关系的现成教案）。
