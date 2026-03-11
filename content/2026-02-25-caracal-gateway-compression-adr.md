---
title: 技术决策记录 (ADR)：caracal-gateway 压缩选型方案
date: 2026-02-25 10:00:00
tags: [Architecture, Gateway, ADR, Zstd, Go, Compression]
---


## 背景
在 `caracal-gateway` 传输网关中，需要处理包括视频、证书、OFD文档等在内的多种文件。为了在提升传输效率的同时，最小化 CPU 资源开销，特制定本压缩选型方案。

## 选型分析与策略

### 1. 视频类文件 (Video Files)
- **分析**：MP4, TS, MKV 等视频文件本身已高度压缩（有损压缩）。对其进行二次通用无损压缩（如 Gzip, Zstd）通常只能获得 <1% 的空间节省，却会消耗大量 CPU 核心时间。
- **策略**：**直接透传 (Pass-through)**。
- **实现**：通过扩展名（.mp4, .ts, .mkv, .avi, .flv 等）或 MIME 类型（video/*）识别，跳过压缩引擎，直接进行 IO 流式复制。

### 2. 证书类文件 (Certificates/Keys)
- **分析**：证书文件（PEM/DER）通常极小（1KB-4KB），包含大量 Base64 文本和标准化的颁发者/结构字段。普通压缩算法在如此小的数据块上很难建立有效字典。
- **策略**：**Zstandard (Zstd) + 静态字典模式 (Dictionary Mode)**。
- **实现**：预先通过样本数据训练并加载静态字典。在处理 `.pem`, `.crt`, `.key` 等文件时，携带字典进行压缩，可将压缩比从 1.5x 提升至 3x-5x，显著降低传输量。

### 3. OFD 文档 (OFD Files)
- **分析**：OFD 是国家标准版式文档，物理结构本质上是 ZIP 归档包，内部内容（XML 和图片）已处于压缩状态。
- **策略**：**识别透传**。
- **实现**：识别 `.ofd` 后缀，默认不进行二次压缩，避免 CPU 浪费。

## 技术实现 (Go 语言)

### 推荐库
- **库名**：`github.com/klauspost/compress/zstd`
- **理由**：
    - **无 CGO 依赖**：纯 Go 实现，便于跨平台编译部署，无动态链接库烦恼。
    - **高性能**：针对现代 CPU 指令集（AVX2/SSE）进行了深度优化，速度远超标准库。
    - **内存友好**：支持 Writer/Reader 池化机制，极大降低高并发下的 GC（垃圾回收）压力。

### 核心逻辑设计建议
```go
func (g *Gateway) HandleFileTransfer(fileName string, src io.Reader, dst io.Writer) error {
    ext := filepath.Ext(fileName)
    
    switch ext {
    // 1. 已压缩格式：直接透传，追求 0 CPU 损耗
    case ".mp4", ".ts", ".ofd", ".zip", ".png", ".jpg":
        _, err := io.Copy(dst, src)
        return err

    // 2. 证书/密钥：字典压缩，追求极致压缩比
    case ".pem", ".crt", ".key":
        // 需预先加载训练好的字典文件
        return g.compressWithZstdDict(dst, src)

    // 3. 通用文本/未知类型：常规 Zstd 压缩
    default:
        return g.compressWithZstdGeneric(dst, src)
    }
}
```

## 结论
- **视频与OFD**：作为“已压缩”类型对待，执行透传策略以节省网关算力。
- **证书与元数据**：作为“高价值可压”类型对待，采用 Zstd 字典模式以节省带宽。
- **通用工具链**：全量采用 **klauspost/compress** 生态，确保高性能与工程化便捷性。

---
*记录日期：2026年2月25日*
