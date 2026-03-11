---
title: 在chirpy使能评论系统(ai)
date: 2025-12-02 00:11:00
pin: true
tags: [blog, chirpy]
---



# 如何在 Chirpy 主题中开启评论功能

Chirpy 主题内置了多种评论系统的支持，其中 **Giscus** 是目前最推荐的方案（免费、无广告、基于 GitHub Discussions）。

以下是开启 **Giscus** 评论功能的详细步骤：

## 第一步：准备 GitHub 仓库

1.  确保你的博客仓库是 **Public（公开）** 的。
2.  在你的博客仓库中开启 **Discussions** 功能：
    *   进入仓库的 `Settings` -> `General`。
    *   向下滚动找到 `Features` 区域。
    *   勾选 `Discussions`。

## 第二步：获取 Giscus 配置参数

你需要去 Giscus 官网生成属于你仓库的专属 ID。

1.  访问 [giscus.app](https://giscus.app/zh-CN)。
2.  **配置仓库**：输入你的 `用户名/仓库名`（例如 `hlwqds/hlwqds.github.io`）。
3.  **页面与 Discussion 的映射关系**：推荐选择 “Discussion 的标题包含页面的 URL” (`pathname`)。
4.  **Discussion 分类**：推荐选择 “General” 或 “Announcements”（确保你选的分类在 GitHub Discussions 里是允许任何人发帖的）。
5.  **获取配置**：
    向下滚动，你会看到一段生成的代码。我们需要其中的 `data-repo-id` 和 `data-category-id` 这两个值。

## 第三步：修改 `_config.yml`

回到你的本地代码，打开根目录下的 `_config.yml` 文件。

1.  找到 `comments:` 部分。
2.  将 `active` 修改为 `giscus`。
3.  在 `giscus:` 下方填入你刚才获取的 ID。

配置示例如下：

```yaml
comments:
  # 1. 激活评论系统
  active: giscus

  # 2. 填写 Giscus 配置
  giscus:
    repo: hlwqds/hlwqds.github.io   # 你的 用户名/仓库名
    repo_id: R_kgDxxxxxxx           # 填入从 giscus.app 获取的 data-repo-id
    category: General               # 分类名称
    category_id: DIC_kwDxxxxxxx     # 填入从 giscus.app 获取的 data-category-id
    mapping: pathname               # 映射方式
    strict: 0
    reactions_enabled: 1
    input_position: bottom          # 输入框位置
    lang: zh-CN                     # 语言设置
```

## 第四步：验证与部署

1.  **推送到 GitHub**：
    ```bash
    git add _config.yml
    git commit -m "Enable Giscus comments"
    git push
    ```

2.  **等待构建**：
    GitHub Actions 构建完成后，访问你的博客文章页面，底部应该会出现评论框。

> **注意**：Chirpy 主题默认在本地预览模式 (`jekyll serve`) 下隐藏评论区。如果想在本地查看，请使用 `JEKYLL_ENV=production bundle exec jekyll serve` 启动。
