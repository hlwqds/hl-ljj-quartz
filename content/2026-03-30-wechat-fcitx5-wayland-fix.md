---
title: 微信 Linux 在 Wayland 下 fcitx5 输入法修复
date: 2026-03-30 10:00:00
tags: [wechat, fcitx5, wayland, linux]
---

# 微信 Linux 在 Wayland 下 fcitx5 输入法修复

## 问题

微信 Linux 4.1.1.4 在 niri (Wayland) 下无法调出 fcitx5 中文输入法。

## 环境

- 系统：Fedora 43 (Server Edition)
- 桌面：niri (Wayland compositor)
- 微信：wechat 4.1.1.4（xwechat 架构）
- 输入法：fcitx5

## 原因分析

微信的主进程基于 Qt，子进程 `WeChatAppEx` 基于 Chromium。即使设置 `QT_QPA_PLATFORM=xcb` 强制 Qt 走 XWayland，Chromium 子进程仍会通过 Wayland 原生协议注册 InputContext（`frontend:wayland_v2`），导致 fcitx5 无法正确响应。

通过 `fcitx5-diagnose` 可以确认：

```
IC [...] program:wechat frontend:wayland_v2 cap:100000072 focus:0
```

`focus:0` 表示输入法焦点未正确获取。

## 解决方案

修改 `~/.local/share/applications/wechat.desktop` 的 `Exec` 行：

```bash
cp /usr/share/applications/wechat.desktop ~/.local/share/applications/
```

```ini
Exec=env WAYLAND_DISPLAY= QT_QPA_PLATFORM=xcb XIM="fcitx" QT_IM_MODULE=fcitx QT_AUTO_SCREEN_SCALE_FACTOR=1 /usr/bin/wechat %U
```

### 关键参数说明

| 参数                            | 作用                                                          |
| ------------------------------- | ------------------------------------------------------------- |
| `WAYLAND_DISPLAY=`              | 彻底隐藏 Wayland，强制所有子进程（含 WeChatAppEx）走 XWayland |
| `QT_QPA_PLATFORM=xcb`           | Qt 后端使用 XCB 而非原生 Wayland                              |
| `XIM="fcitx"`                   | 通过 XIM 协议连接 fcitx                                       |
| `QT_IM_MODULE=fcitx`            | 注意不是 `fcitx5`，Chromium 对 `fcitx` 兼容性更好             |
| `QT_AUTO_SCREEN_SCALE_FACTOR=1` | 在 XWayland 下自动处理缩放                                    |

### 排坑记录

1. 仅设置 `QT_QPA_PLATFORM=xcb` 无效 — WeChatAppEx 子进程仍走 Wayland
2. `QT_IM_MODULE` 必须用 `fcitx` 而非 `fcitx5` — Chromium 子进程对后者支持不完善
3. 根本解决办法是 `WAYLAND_DISPLAY=` — 隐藏 Wayland 后所有进程统一走 XWayland + XIM
