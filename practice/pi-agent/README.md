# Pi Agent 深度探索配套实验

这里存放 `Pi Agent 深度探索系列` 的可运行实验。实验与文章按阶段对应，但每个阶段都能独立运行。

## 安全约定

- 实验默认在普通用户和测试目录中运行。
- 环境检查不会安装软件、登录 Provider 或写入 Pi 配置。
- 涉及文件修改的后续实验会使用独立目录，并提供清理步骤。
- 真实 API Key 只通过环境变量或本机凭据存储提供，不写入示例文件。
- Pi 默认不是权限沙箱。需要强隔离时，应在容器或其他受控环境中运行。

## 实验索引

| 阶段 | 目录                         | 内容                              | 状态 |
| ---- | ---------------------------- | --------------------------------- | ---- |
| 1    | `phase-1-environment/`       | Node、npm、Git、pnpm、Pi 环境检查 | 可用 |
| 2    | `phase-2-minimal-agent/`     | 无 TUI 的最小 Agent Loop          | 计划 |
| 3    | `phase-3-event-trace/`       | 记录并还原一次完整事件链          | 计划 |
| 4    | `phase-4-project-extension/` | 项目分析 Extension                | 计划 |
| 5    | `phase-5-branded-agent/`     | 最小品牌化 Coding Agent           | 计划 |

只创建已经交付的实验目录，避免把空目录误认为可运行内容。

## 首批验证

在 Quartz 仓库根目录运行：

```bash
node practice/pi-agent/validate-first-batch.mjs
```

该脚本检查：

- 系列索引和前五篇文章是否存在；
- Frontmatter 是否包含必要字段；
- 源码链接是否固定到完整 commit SHA；
- 首批 Wiki Link 是否可解析；
- 环境脚本是否保持只读。
