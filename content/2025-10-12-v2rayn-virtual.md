---
title: 虚拟机v2ray配置
date: 2024-10-12 00:11:00
pin: true
tags: [tools, virtual]
---


# 虚拟机v2ray配置

## 方法

查看虚拟网卡的地址

```powershell
ipconfig
   本地链接 IPv6 地址. . . . . . . . : fe80::76c5:e5f3:a00b:65d%18
   IPv4 地址 . . . . . . . . . . . . : 192.168.124.1
   子网掩码  . . . . . . . . . . . . : 255.255.255.0
```

在bashrc中配置
```bash
# ~/.bashrc
# add for proxy
export hostip=$(ip route | grep default | awk '{print $3}')
export hostport=10809
alias proxy='
    export HTTPS_PROXY="http://${hostip}:${hostport}";
    export HTTP_PROXY="http://${hostip}:${hostport}";
    export ALL_PROXY="http://${hostip}:${hostport}";
    echo -e "Acquire::http::Proxy \"http://${hostip}:${hostport}\";" | sudo tee -a /etc/apt/apt.conf.d/proxy.conf > /dev/null;
    echo -e "Acquire::https::Proxy \"http://${hostip}:${hostport}\";" | sudo tee -a /etc/apt/apt.conf.d/proxy.conf > /dev/null;
'
alias unproxy='
    unset HTTPS_PROXY;
    unset HTTP_PROXY;
    unset ALL_PROXY;
    sudo sed -i -e '/Acquire::http::Proxy/d' /etc/apt/apt.conf.d/proxy.conf;
'
```

在虚拟机中配置代理

```bash
proxy
```

取消代理

```bash
unproxy
```


## wsl设置

开始菜单搜索wsl setting，指定网络模式为mirrored模式
