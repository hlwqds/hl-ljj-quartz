---
title: "面向 AI 的技术花园协作规范 (Open Spec v1.0)"
date: 2026-03-11
tags: [spec, ai, workflow, meta, obsidian]
---

> [!abstract] 导读
> 本文档定义了 AI 代理在参与 `hlwqds.github.io` 知识库建设时的标准操作流程（SOP）。旨在确保所有生成的内容符合 Obsidian 语法标准，保持跨文档引用的一致性，并优化在 Quartz 环境下的呈现效果。

## 1. 核心架构准则

AI 在生成新内容或修改现有内容时，必须遵循以下层级结构：

- **内容存储**：所有 Markdown 文章必须存放于 `content/` 根目录。
- **静态资源**：图片、PCAP 抓包文件、PDF 等非文本资源统一存放于 `content/assets/`。
- **引用协议**：
    - 内部引用优先使用 **Wikilinks**：`[[文件名|显示文本]]`。
    - 资源引用：`![[文件名.png]]`。

## 2. 格式化标准

### 2.1 Frontmatter 规范
每篇文章必须包含完整的 YAML 元数据，格式如下：
```yaml
---
title: "文章标题"
date: YYYY-MM-DD
tags: [tag1, tag2]
pin: false # 可选，是否置顶
---
```
> [!warning] 注意
> 严禁使用 `categories` 字段，所有分类逻辑必须通过 `tags` 数组合并实现。

### 2.2 扩展语法支持
AI 应充分利用以下增强语法提升可读性：
- **Callouts**：使用 `> [!info]`、`> [!check]`、`> [!danger]` 标注关键信息。
- **Mermaid**：用于流程图和架构图。参见示例：[[2025-11-27-suricata-ip-reputation|Suricata 部署图示]]。
- **数学公式**：使用 LaTeX 语法，由 KaTeX 渲染。参考：[[2025-10-17-rfc1813-zh|RFC1813 协议细节]]。
- **块引用与脚注**：
    - 使用 `^blockid` 进行段落标记。
    - 使用 `[^1]` 和 `[^1]: 描述` 进行补充说明。
- **高亮**：使用 `==文本==` 进行重点标注。

## 3. 引用与索引体系

### 3.1 跨文档知识缝合
AI 在撰写新文档时，必须检索现有仓库并进行“强制缝合”引用。

**核心系列引用对照表：**
- **DeepFlow 深度分析系列**：
    - [[2026-03-08-deepflow-detailed-analysis-report|架构分析报告]]
    - [[2026-03-08-deepflow-strategy-and-implementation|策略下发机制]]
    - [[2026-03-08-deepflow-traffic-capture-technology|流量采集技术]]
- **DPDK 高性能开发系列**：
    - [[2025-12-31-dpdk_callbacks_guide|Callbacks 深度指南]]
    - [[2025-12-16-dpdk-tx-offload-mbuf-fast-free|MBUF 快速释放]]
    - [[2026-01-04-ip_reassembly_analysis|IP 重组逻辑]]
- **Suricata 引擎研究系列**：
    - [[2025-11-27-suricata-flow-state|Flow 状态机分析]]
    - [[2025-11-27-suricata-proto-detect-done|协议检测标记位]]
    - [[2026-02-09-suricata-advanced-acl-auditing|高级 ACL 审计]]

### 3.2 外部参考引用
文档末尾必须包含 `## 外部参考` 章节，采用如下格式：
- [Quartz 官方文档](https://quartz.jzhao.xyz/)
- [Obsidian 帮助中心](https://help.obsidian.md/)

## 4. AI 协作协议 (AI Interaction Protocol)

当用户发出指令要求 AI 编写文档时，AI 应当执行：
1. **Context Check**：检索 `content/` 目录下相关的 `.md` 文件。
2. **Schema Matching**：检查 `quartz.config.ts` 确认已启用的插件（如当前已启用 Mermaid, Latex）。
3. **Drafting**：生成符合上述规范的草案。
4. **Validation**：运行 `npx quartz build` 确保无 YAML 语法错误。

---
## 外部参考与资源
- [Cilium pwru 项目](https://github.com/cilium/pwru) - 网络分析参考
- [Catppuccin 配色指南](https://catppuccin.com/) - 视觉标准引用
- [eCapture 项目](https://ecapture.cc/) - TLS 解密技术参考
