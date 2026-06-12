# 第一阶段实验：Pi 环境检查

本实验确认当前机器是否满足 Pi 的基础运行条件，并展示发布包与源码两条使用路径。

本文对应的 Pi 源码快照：

```text
repository: https://github.com/earendil-works/pi
commit: 1da903983ad72c60995507e813a00bb2bd6faf09
package version: 0.79.1
required Node.js: >=22.19.0
```

## 运行检查

从 Quartz 仓库根目录运行：

```bash
cd practice/pi-agent/phase-1-environment
bash check-environment.sh
```

脚本检查：

- 必需：`node`、`npm`、`git`；
- 可选：`pnpm`、`pi`；
- Node.js 是否满足 `>=22.19.0`。

脚本不会：

- 安装或卸载软件；
- 启动 Pi 登录流程；
- 访问 Provider；
- 创建或修改 `~/.pi`；
- 修改当前仓库。

## 预期输出

已安装 Pi 时，输出类似：

```text
[PASS] node: /usr/bin/node (v24.16.0)
[PASS] node requirement: v24.16.0 satisfies >=22.19.0
[PASS] npm: /usr/bin/npm (11.13.0)
[PASS] git: /usr/bin/git (git version 2.53.0)
[PASS] pnpm: /usr/bin/pnpm (10.12.1)
[PASS] pi: /home/user/.local/bin/pi (0.79.1)
[PASS] required environment checks completed
```

没有安装可选命令时：

```text
[SKIP] pnpm: command not found (optional)
[SKIP] pi: command not found (optional)
```

如果必需命令缺失或 Node 版本过低，脚本返回非零状态。

## 路径一：使用发布包

官方 npm 安装命令：

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
pi --version
```

不希望全局安装时，可以临时执行：

```bash
npm exec --yes --package=@earendil-works/pi-coding-agent -- pi --version
```

临时执行会使用 npm 缓存，但不会把 `pi` 注册为长期全局命令。

## 路径二：使用源码

在自行选择的实验目录中运行：

```bash
git clone https://github.com/earendil-works/pi.git
cd pi
git checkout 1da903983ad72c60995507e813a00bb2bd6faf09
npm install --ignore-scripts
npm run build
./pi-test.sh
```

如果需要跟踪最新 `main`，跳过固定 SHA 的 checkout，并记录实际版本：

```bash
git rev-parse HEAD
```

后续源码章节使用这条路径。

## 认证交接

环境检查通过后，再单独选择认证方式：

```text
订阅账号     -> 启动 pi 后执行 /login
API Key      -> 设置对应 Provider 环境变量
云 Provider  -> 配置 AWS Profile、Google ADC 等凭据链
```

本实验不验证真实模型请求，因为那会依赖个人凭据和 Provider 计费。

## 清理

环境检查本身不产生需要清理的文件。

如果你创建了源码实验目录，只删除你自己创建且已经确认路径的目录。例如，源码位于
`/tmp/pi-source-lab` 时：

```bash
rm -rf /tmp/pi-source-lab
```

不要为了卸载 CLI 直接删除整个 `~/.pi/agent/`。其中可能包含需要保留的 Session、设置和凭据。
