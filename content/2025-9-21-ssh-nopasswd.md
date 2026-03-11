---
title: ssh免密登录
date: 2024-09-21 00:11:00
pin: true
tags: [ssh, network, linux, tools]
---


# ssh免密登录

记录window ssh免密登录方法

## 本地生成公钥

```bash
ssh-keygen -t rsa
```

## 将公钥上传至服务器

```bash
# windows侧
cd C:\Users\%用户名%\.ssh\
scp id_rsa.pub user@host:~/.ssh
# linux侧
cd ~/.ssh
cat id_rsa.pub >> authorized_keys
```
