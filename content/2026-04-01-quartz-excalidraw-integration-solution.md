---
title: Quartz 与 Excalidraw 自动化集成方案深度解析
date: 2026-04-01
tags: [quartz, excalidraw, automation, ssg, architecture]
---

> [!abstract] 核心概述
> 在构建技术文档库时，高质量的架构图是核心资产。本文详细介绍了如何在 Quartz (v4) 中实现 **Excalidraw 绘图的无缝集成**，并支持 **亮/暗模式自动切换**。
>
> - **原理**：Obsidian 自动导出 + Quartz 插件重写 + 前端脚本动态切换。
> - **优势**：高性能、零依赖、SEO 友好且支持暗色模式。

---

# Quartz 与 Excalidraw 自动化集成方案深度解析

## 一、 方案背景与目标

Quartz 原生并不支持直接渲染 `.excalidraw` 这种 JSON 格式的绘图文件。传统的解决方案（如在构建时进行 Node.js 转换）往往依赖繁重的原生图像库（如 Cairo），在 CI/CD 环境中极不稳定。

**我们的方案目标：**

1. **高性能**：直接加载 SVG，无需前端运行庞大的渲染引擎。
2. **自动化**：在 Obsidian 中画图，保存即生效，无需手动转换。
3. **沉浸式体验**：绘图颜色随网站亮/暗模式**自动同步切换**。
4. **SEO 友好**：SVG 内的文本可被搜索引擎索引。

---

## 二、 核心架构图

以下展示了该方案的数据流向（此图使用 Excalidraw 绘制，并由我们的插件自动处理）：

![Quartz Excalidraw 集成架构图](./traffic_collection_flow.excalidraw)

> [!tip] 亮暗模式测试
> 尝试点击网站右上角的太阳/月亮图标，你会发现上方的架构图颜色会随之平滑切换！

---

## 三、 实现原理：三位一体的联动

该方案由三个核心组件协同工作：

### 1. Obsidian 端：自动导出引擎

利用 Obsidian 的 Excalidraw 插件，配置 **Auto-export** 功能。

- **动作**：每当 `.excalidraw` 保存时，自动在同级目录生成 `name.light.svg` 和 `name.dark.svg`。
- **优势**：利用本地计算资源完成最耗时的渲染工作，保持构建服务器轻量化。

### 2. Quartz Transformer：智能路径重写

我们开发了专用的 `ExcalidrawResolution` 插件（位于 `quartz/plugins/transformers/excalidraw.ts`）。

- **逻辑**：扫描 Markdown 中的 `![[drawing.excalidraw]]` 引用。
- **输出**：在 HTML 构建阶段，将其转换为带特殊类名（`.excalidraw-diagram`）和 `data-basename` 属性的标准 `<img>` 标签。

### 3. 前端脚本：动态主题切换

在 `quartz/components/scripts/util.ts` 和 `darkmode.inline.ts` 中注入逻辑。

- **逻辑**：监听 Quartz 的 `themechange` 事件。
- **动作**：当主题切换时，利用 JavaScript 实时修改所有 `.excalidraw-diagram` 图片的 `src` 属性，在 `.light.svg` 和 `.dark.svg` 之间无缝跳转。

---

## 四、 如何在你的笔记中使用？

只需像往常一样在 Obsidian 中引用你的绘图即可，无需关心后缀名：

```markdown
# 标准 Obsidian 语法

![[我的系统架构图.excalidraw]]

# 标准 Markdown 语法

![架构图](./my-diagram.excalidraw)
```

---

## 五、 总结与优势

| 维度         | 传统方案                     | 本方案                            |
| :----------- | :--------------------------- | :-------------------------------- |
| **构建速度** | 慢（需调用 headless 浏览器） | **极快**（仅正则匹配与文件拷贝）  |
| **部署难度** | 极高（需安装大量 C++ 库）    | **零依赖**（纯 TypeScript 实现）  |
| **交互体验** | 静态图片                     | **动态主题感知**                  |
| **维护成本** | 高（插件易随版本失效）       | **极低**（基于 Quartz 原生 Hook） |

通过这套方案，你可以将更多的精力放在**技术内容的产出**上，而让绘图的渲染与同步完全自动化。
