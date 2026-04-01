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

### 2.3 Mermaid 语法约束 (重要)

为确保 Mermaid 图表在 Quartz 环境下的稳定性，AI 在生成图表时必须遵循以下禁令：

- **禁止数字点前缀**：严禁在连线描述（Edge Labels）中使用“数字+点”的格式（如 `-- "1. Auth" -->`）。即使使用了引号，渲染引擎仍会将其误判为 Markdown 有序列表导致解析崩溃。
- **推荐替代方案**：
  - 使用纯文字（如 `-- "Authenticate" -->`）。
  - 使用不带点的数字（如 `-- "1 Auth" -->`）。
- **布局建议**：优先使用 `graph LR` (横向布局) 以提升移动端和侧边栏共存时的阅读体验。
- **颜色注入**：避免在代码块中使用 `style` 标签手动注入颜色，应依赖 **Tokyo Night** 主题的全局 CSS 进行统一渲染。

## 3. 引用与索引体系

### 3.1 跨文档知识缝合

AI 在撰写新文档时，必须检索现有仓库并进行“强制缝合”引用。

**核心系列引用对照表：**

- **软件定义安全边界 (SDP) 系列**：
  - [[2026-03-11-sdp-zero-trust-overview|1. 概论与范式转移]]
  - [[2026-03-11-sdp-cloud-infrastructure-security|2. 基础设施隔离]]
  - [[2026-03-11-sdp-kernel-path-deep-dive|3. 内核路径深究]]
  - [[2026-03-11-sdp-application-identity-mtls|4. 应用身份与加密]]
  - [[2026-03-11-sdp-advanced-threat-defense|5. 纵深防御进阶]]
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

### 3.3 逻辑内嵌引用 (Embedded Logic Linking)

AI 在撰写正文时，必须将仓库内现有的知识点作为“逻辑论据”直接嵌入到段落中：

- **强制嵌入**：禁止仅在文末罗列相关文章。当正文提到某一技术概念（如 eBPF, XDP, mTLS）时，必须通过 Wikilinks 引用对应的深度分析文章。
- **示例**：
  - _错误做法_：在 SDP 文章中仅提到“我们需要高性能拦截”。
  - _正确做法_：在 SDP 文章中写到“利用 **[[2025-12-16-dpdk-tx-offload-mbuf-fast-free|DPDK 高性能转发]]** 配合 **[[2026-03-08-deepflow-detailed-analysis-report|DeepFlow eBPF 采集技术]]** 可以在宿主机层面实现无损拦截。”
- **引用完整性**：引用时必须保留原有的日期前缀（如 `[[2025-12-31-dpdk_callbacks_guide]]`），以确保 Quartz 路由正确。

## 4. AI 协作协议 (AI Interaction Protocol)

当用户发出指令要求 AI 编写文档时，AI 应当执行：

1. **Context Check**：检索 `content/` 目录下相关的 `.md` 文件。
2. **Schema Matching**：检查 `quartz.config.ts` 确认已启用的插件（如当前已启用 Mermaid, Latex）。
3. **Drafting**：生成符合上述规范的草案。
4. **Validation**：运行 `npx quartz build` 确保无 YAML 语法错误。

---

## 外部参考与资源

- [Cilium pwru 项目](https://github.com/cilium/pwru) - 网络分析参考
- [Tokyo Night 配色指南](https://github.com/folke/tokyonight.nvim) - 视觉标准引用
- [eCapture 项目](https://ecapture.cc/) - TLS 解密技术参考
