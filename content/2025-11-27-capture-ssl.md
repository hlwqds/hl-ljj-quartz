---
title: 抓取ssl明文数据工具
date: 2025-11-26 00:11:00
pin: true
tags: [capture, tool, network, ssl]
---

# 记录一次ftp-data流量乱序导致的suricata始终不输出fileinfo

## 现象

回放[乱序包](2025-11-26-pcap-collection.md#ftp 挥手也乱序)后，fileinfo事件始终不产生

```bash
./src/suricata -c /root/caracal/watermark.yaml -k none -r /root/caracal/pcap/ --pcap-file-continuous
```

## 调试步骤

```gdb
# 首先关闭randomhash, 这个会导致hashindex随机
--no-random

b JsonFileLogger
# 查看堆栈，查看关机时是如何触发tx打印的，再查找上下文有没有超时处理程序

# 退出时从fls.work_queue中取出
FlowWorkerProcessLocalFlows

# 超时时从flowhash中取出
FlowManagerFlowTimeout 由flowmanager定时处理，需要注意我在这里使用的是pcap回放，suricata不会对其进行超时处理(也许是一个bug)，这是导致一直没有flow超时，输出tx的原因。
```
