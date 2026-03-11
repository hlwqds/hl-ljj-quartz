---
title: windows禁用自带的键盘
date: 2024-09-22 00:11:00
pin: true
tags: [tools, windows]
---

# windows禁用自带的键盘

## 方法

```powershell
# 以管理员权限执行cmd，运行以下命令，然后重启
sc config i8042prt start= disabled
```
