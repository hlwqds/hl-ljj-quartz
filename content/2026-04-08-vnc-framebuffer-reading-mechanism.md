---
title: VNC 帧缓冲区读取机制：物理机与虚拟机的差异
date: 2026-04-08 00:00:00
tags: [vnc, remote-desktop, framebuffer, qemu, kvm]
---

# VNC 帧缓冲区读取机制：物理机与虚拟机的差异

> [!info] VNC 协议系列
> - [[2026-04-08-vnc-protocol-and-traffic-fingerprint|VNC 协议原理与流量特征分析]]
> - **VNC 帧缓冲区读取机制：物理机与虚拟机的差异**（本文）
> - [[2026-04-08-vm-installation-without-vnc|虚拟机无 VNC 安装方案：纯文本全链路管理]]

## 核心问题

VNC Server 是如何读取屏幕像素并传输到对端的？这取决于运行环境，物理机和虚拟机有**完全不同的实现路径**。

## Linux 显示架构基础

先理解 Linux 的显示栈：

```
应用程序 (X11/Wayland 客户端)
       │
       ▼
┌─────────────┐
│  X Server   │  或  Wayland Compositor
│  / display  │
└──────┬──────┘
       │ 写入像素
       ▼
┌─────────────┐
│  Linux FB   │  /dev/fb0   或   DRM/KMS 显存
│  Framebuffer│  ← 内核管理的一块内存，即"帧缓冲区"
└─────────────┘
       │ GPU DMA 刷到屏幕
       ▼
    显示器
```

VNC Server 本质上就是**定期读取这块内存中的像素，对比变化，编码后通过网络发出去**。

## 场景一：物理机 / 普通 Linux 桌面

### 方式 1：x11vnc — 寄生在 X Server 上（最常见）

x11vnc 不直接读 /dev/fb0，而是通过 X11 协议让 X Server 把像素给它：

```
x11vnc
  │
  │  XShmGetImage() / XGetImage()
  ▼
X Server（把显存拷贝到 x11vnc 的用户态内存）
  │
  ▼
像素对比 → 找脏区域 → 编码 → RFB 发送
```

核心逻辑伪代码：

```c
while (1) {
    // 通过共享内存扩展抓取当前屏幕
    XShmGetImage(display, window, shm_image, 0, 0, AllPlanes);

    // 跟上次抓的图做 tile 级像素对比
    for (y = 0; y < height; y += tile_size) {
        for (x = 0; x < width; x += tile_size) {
            if (tile_changed(old_buf, new_buf, x, y)) {
                add_changed_rect(x, y, w, h);
            }
        }
    }

    // 只把变化的矩形编码发送
    send_framebuffer_update(changed_rects);
    usleep(16000); // ~60fps
}
```

### 方式 2：直接读 /dev/fb0 — 嵌入式 / 无 X Server

```c
int fd = open("/dev/fb0", O_RDWR);
struct fb_var_screeninfo vinfo;
ioctl(fd, FBIOGET_VSCREENINFO, &vinfo);

// mmap 把显存映射到用户态地址空间
size_t screensize = vinfo.xres * vinfo.yres * vinfo.bits_per_pixel / 8;
unsigned char *fbp = (unsigned char *)mmap(
    0, screensize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);

// 直接读像素，每个像素就是 fbp 里的几个字节
// 后续：对比变化 → 编码 → 发送
```

### 方式 3：Wayland 下的 wayvnc

Wayland 禁止客户端直接读屏幕，走 compositor 提供的 `wlr-screencopy` 等协议：

```
wayvnc ← wlr-screencopy 协议 ← Compositor（拥有实际像素）
                                      │
                                  只有 compositor 能截屏
```

## 场景二：虚拟机 — QEMU/KVM

虚拟机场景下**完全不需要 Guest OS 配合**，因为 VMM 天然拥有虚拟显存的访问权。

```
Guest OS (Linux/Windows...)
       │ 以为自己在正常写显卡
       ▼
┌──────────────────┐
│  虚拟显卡 (QXL/  │   ← QEMU 模拟的 VGA 设备
│  Virtio-GPU/     │       Guest 的显卡驱动往这里写像素
│  VGA)            │
└──────┬───────────┘
       │ QEMU 在宿主机进程中维护这块虚拟显存
       ▼
┌──────────────────┐
│  QEMU 进程       │   ← VNC Server 就跑在 QEMU 里
│  (宿主机用户态)   │       直接访问自己管理的虚拟显存
│  内置 VNC Server │       不经过 Guest 内核，Guest 无需安装任何东西
└──────────────────┘
       │ RFB over TCP
       ▼
    VNC Client
```

QEMU 内置 VNC 的实现（`ui/vnc.c` 简化）：

```c
// 1. 虚拟显卡刷新时，回调通知 VNC 有区域变化
static void vnc_dpy_update(DisplayChangeListener *dcl,
                           int x, int y, int w, int h)
{
    VncDisplay *vd = container_of(dcl, VncDisplay, dcl);
    // 标记脏区域
    vnc_set_area_dirty(vd->dirty, x, y, w, h);
}

// 2. VNC 定时把脏区域编码发送给所有客户端
static void vnc_refresh(DisplayChangeListener *dcl)
{
    VncDisplay *vd = container_of(dcl, VncDisplay, dcl);
    // 编码线程：取脏区域像素 → 对比 → 压缩 → 发送
    vnc_job_push(vd);
}
```

## 两种场景的对比

| 维度 | 物理机 | 虚拟机 (QEMU/KVM) |
|------|--------|-------------------|
| 帧缓冲区位置 | 内核管理的 /dev/fb0 或 DRM 显存 | QEMU 进程的用户态堆内存 |
| 读取方式 | X11 协议 / mmap / screencopy | 直接访问进程内内存 |
| VNC Server | 独立进程（x11vnc / TightVNC 等） | QEMU 内置模块 |
| Guest/OS 感知 | OS 感知（需要 X Server 或 FB 设备） | **完全无感知** |
| 性能瓶颈 | X Server 拷贝开销 / mmap 同步 | 虚拟显卡 I/O 路径 |
| 需要安装软件 | 是（VNC Server） | 否（QEMU 自带） |

## 总结

```
物理机：  App → X/Wayland → 显存 → VNC Server 抓显存 → 编码发送
                   ↑
              OS 提供，VNC Server 是普通用户态程序，需要"想办法读"

虚拟机：  Guest App → 虚拟显卡驱动 → QEMU 虚拟显存 → QEMU 内置 VNC → 发送
                                              ↑
                                     VMM 就是显卡实现者，显存是自己的内存
```

核心区别：物理机上 VNC Server 要想办法"偷看"屏幕内容，而虚拟机里 **QEMU 本身就是显卡的实现者**，显存本来就是它的内存，天然拥有访问权，不需要任何特殊手段。
