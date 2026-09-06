---
title: "ESP32-S3-BOX-3 工程实战（十九）：ESP-DL 模型部署"
date: 2026-08-26 12:00:00
description: "BOX-3 本体没有摄像头，但「把神经网络塞进 S3」的方法论与输入模态无关：从为什么必须量化（int8 vs float 的内存与带宽账，官方加速比逐条注明出处），到 esp-ppq 量化工具链与 .espdl 模型格式，再到 esp-nn 向量指令加速发生在哪一层，最后落在推理任务与张量内存放置的工程决策上。"
tags: [esp32, esp32-s3, esp-idf, series, ai]
---

# ESP32-S3-BOX-3 工程实战（十九）：ESP-DL 模型部署

第十八章把语音线（esp-sr）讲完了：WakeNet 怎么唤醒、推理任务怎么给优先级。本章把镜头从"语音"拉回到更一般的问题——**一个训练好的神经网络，怎么部署到 ESP32-S3 上跑起来**。乐鑫给出的通用答案是 ESP-DL。先把丑话说在前面：BOX-3 本体没有摄像头，所以本章不承诺"跟我做就能在 BOX-3 上跑人脸检测"；它讲的是方法论，视觉输入需要额外硬件，开篇 19.1 节把边界交代清楚。

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[esp32-s3-box-3|系列索引]]
> 上一章：[[ch18-esp-sr-wakeword|第十八章：ESP-SR 语音唤醒]]
> **第十九章：ESP-DL 模型部署**（当前章）
> 下一章：[[ch20-capstone-voice-remote|第二十章：综合项目]]

---

## 19.1 定位与诚实边界：一块没有摄像头的板子，为什么还要讲视觉部署

BOX-3 标准套件的本体是：2.4 寸屏（ILI9342C）+ 双 mic（ES7210）+ 扬声器（ES8311）+ 红外收发（SENSOR 板），**没有摄像头**。这不是我猜的，乐鑫自己的视觉示例仓库 esp-who（master，2026-08-26 核实）支持的板子只有三块：

| 板子                       | SoC     | 与视觉相关的硬件（esp-who README） |
| -------------------------- | ------- | ---------------------------------- |
| ESP32-P4 Function EV Board | esp32p4 | LCD、touch、uSD、audio             |
| ESP32-S3-EYE               | esp32s3 | camera、LCD（st7789）、uSD         |
| ESP32-S3-Korvo-2           | esp32s3 | camera、LCD（ili9341）、touch、uSD |

BOX-3 不在列。所以本章的定位用一张表说死：

| 想做什么                 | 现实路径                                                               | 本章态度                                 |
| ------------------------ | ---------------------------------------------------------------------- | ---------------------------------------- |
| 在 BOX-3 上跑视觉推理    | 经 DOCK/BREAD 转接板外接摄像头模组（自行连线、自行接 esp-camera 驱动） | 无官方背书，属扩展玩法，待真机验证       |
| 用带摄像头的官方板跑视觉 | 换 ESP32-S3-EYE 或 Korvo-2，esp-who 示例开箱即用                       | 正道                                     |
| 学会"模型怎么部署到 S3"  | 本章主线：量化 → 工具链 → runtime → 任务工程学                         | 与输入模态无关，语音/视觉/任意传感器通用 |

方法论之所以通用，是因为第十八章已经给过一个实例：WakeNet/MultiNet 本质上也是"量化后的模型 + 定制 kernel 在 S3 上推理"，esp-sr 只是把它封装成了语音专用组件；ESP-DL 是同一件事的**通用框架版**——你自己训练的模型也能走同一条路。

对第二十章的关系同样要说死：综合项目「语音遥控器」的主线是**唤醒 → 命令识别 → LVGL 反馈 → 红外发射**，全程不需要摄像头。本章是可选扩展线（比如给遥控器加一个"人脸出现才响应"的门控），不是综合项目的前置依赖。跳过本章不影响收官。

---

## 19.2 为什么必须量化：S3 的算力账

结论先说：**在 S3 上跑神经网络，量化到 int8 不是可选项，是入场券**。三个理由：

1. **没有 GPU/NPU**。S3 就是双核 Xtensa LX7 @ 240MHz + 外挂 PSRAM，所有"矩阵乘"最终都是 CPU 指令，没有第三块算力可推。
2. **浮点没有加速可吃**。LX7 的 FPU 是标量单元；S3 真正的加速器是一组**面向 int8 的向量指令**。esp-nn 仓库（README，master）原话："Assembly versions optimised to benefit from vector instructions of ESP32-S3"——优化的是汇编，吃的是向量指令，服务的是 int8 算子。float32 模型在这套加速体系之外。
3. **内存与带宽账**。同一份权重，int8 相对 float32：体积 1/4（Flash/PSRAM 占用）、搬运带宽 1/4（一次总线事务搬 4 倍有效数据）。在 cache 只有 64KB 的 S3 上，推理时间很大程度是"数据搬运时间"（19.6 节展开），带宽减 3/4 直接换速度。

这不是算术游戏，是官方实测的断崖。**出处一：esp-dl 仓库 `operator_performance.md`**（master，2026-08-26 抓取；条件：ESP32-S3 @ 240MHz，Octal PSRAM、SPI QPI 80MHz，数据 cache 64KB / 64B 行；单位为 kernel 执行时间 μs，"ANSI C 参考实现"对比"SIMD 优化版"）：

| 算子（含 bias）    | 形状（PyTorch 记法）                  | ANSI C    | SIMD    | 加速比 |
| ------------------ | ------------------------------------- | --------- | ------- | ------ |
| conv2d 1×1 s1      | 输入 (1,16,20,20)，filter (32,16,1,1) | 11068 μs  | 422 μs  | 26.23× |
| conv2d 3×3 s2      | (1,32,19,23)，(16,32,3,3)             | 25142 μs  | 482 μs  | 52.16× |
| conv2d+ReLU 5×5 s2 | (1,16,22,22)，(32,16,5,5)             | 75451 μs  | 974 μs  | 77.47× |
| conv2d 3×3 s1      | (1,22,19,23)，(33,22,3,3)             | 137933 μs | 3447 μs | 40.02× |
| dwconv2d+ReLU 3×3  | (1,32,100,50)，groups=32              | 96073 μs  | 5542 μs | 17.34× |
| dwconv2d+ReLU 7×7  | (1,25,20,20)，stride (1,2)            | 12772 μs  | 918 μs  | 13.91× |

**出处二：esp-nn 仓库 README** 的整模型级数字（同套 240MHz / QPI 80MHz / 64KB cache 条件）更直观——Person Detection（Visual Wake Words，INT8）：ESP32-S3 从 2300ms 降到 54ms（张量全放内部 RAM 的版本 47ms）；MobileNetV3-Small INT8 224×224×3（TensorArena 在 SPIRAM）：26000ms 降到 1434ms。对照组：无向量指令的经典 ESP32 @ 240MHz 上 Person Detection 是 4084ms→380ms——与 S3 的 54ms 差出一个数量级，反面印证向量指令的价值。

量化方案本身（出处：esp-dl 官方量化教程 `how_to_quantize_model.rst`）：

| 项             | 规则                                                                                    |
| -------------- | --------------------------------------------------------------------------------------- |
| 量化方式       | PTQ（训练后量化），另有 QAT/TQT 进阶路线（教程 `quantize_model_with_TQT.rst`）          |
| 位宽           | 8bit（`s8` 模型）与 16bit 两档                                                          |
| 对称性 / scale | 对称量化，scale 限定为 **2 的幂**（板上只做移位，指数随张量携带）                       |
| 粒度与取整     | ESP32/S3：per-tensor + ROUND_HALF_UP；ESP32-P4：Conv/GEMM per-channel + ROUND_HALF_EVEN |
| batch          | 只支持 batch_size=1                                                                     |

---

## 19.3 工具链全景：从 PC 训练到板端推理

ESP-DL 的完整部署链条（各环节名称均已对照 esp-dl master 官方 README 与教程核实）：

```text
PC 侧                                     板 侧
─────────────────────────────            ─────────────────────────────
训练框架（PyTorch / TF / Paddle / ...）
   │  导出 ONNX（TF/Paddle 需先转 ONNX；
   │  ONNX 模型可被直接读取）
   ▼
esp-ppq 量化（Python 包）                  ESP-IDF 工程
   │  espdl_quantize_onnx /                │  esp-dl 组件（要求 IDF ≥ release/v5.3）
   │  espdl_quantize_torch，PTQ 8/16bit     │   ├─ dl/         核心层与张量
   ▼                                       │   ├─ vision/     视觉前后处理
导出三件套                                  │   ├─ audio/      音频侧
   ├─ model.espdl   ← 部署物 ────────────►  │   └─ fbs_loader/ 模型加载
   ├─ model.info    （调试用文本）           ▼
   └─ model.json    （量化信息存取）        dl::Model 加载 + run() 推理
```

### 1. esp-ppq：量化工具包

2025 年 7 月由 `ppq` 更名而来（避免与同名包冲突，README 原述），入口有两个：`espdl_quantize_onnx`（吃 ONNX）与 `espdl_quantize_torch`（直接吃 PyTorch）。安装（README 给出的 Linux CPU 版 torch 依赖行）：

```bash
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
pip install esp-ppq
```

导出产物固定三件套：

| 文件          | 用途                                                                                                             |
| ------------- | ---------------------------------------------------------------------------------------------------------------- |
| `model.espdl` | 部署物：FlatBuffers 序列化（官方描述"类似 ONNX，但用 FlatBuffers 替代 Protobuf"，零拷贝反序列化），Netron 可打开 |
| `model.info`  | 人读的调试文本：结构、量化后权重、测试输入/输出值——排错第一现场                                                  |
| `model.json`  | 量化信息，可存取复用                                                                                             |

### 2. 板端：esp-dl 组件与 `.espdl`

- 仓库（master）顶层就是 `esp-dl/`（runtime 库本体）、`models/`（模型库）、`examples/`、`docs/`、`test_apps/`、`tools/`；runtime 库内部再分 `dl` / `vision` / `audio` / `fbs_loader` 四个子目录（GitHub API 目录核实）。
- 官方 README 明言"runs based on ESP-IDF"，要求 **ESP-IDF release/v5.3 或更新**——本系列 v6.0.2 满足下限，具体构建表现待真机验证。
- 运行时特性（README 原述）：静态内存规划器（Static Memory Planner）、Conv2D/DepthwiseConv2D 的**双核调度**、ReLU/PReLU 之外的激活统一走 **8bit 查表（LUT）**——都是"围绕 int8 与内存层级做工程"的直接证据。

### 3. 两个版本事实，防新旧混用

1. **`.espdl` 取代了旧时代的 C++ 模型文件**。网上大量旧教程讲"量化后生成 model.cpp/model.h 编进固件"——那是 esp-dl v1.x 的流程（旧分支 `release/v1.1` 仍在，但 README 口径已旧，且当时官方要求"master 分支请配 release/v4.4 ESP-IDF"）。两套流程不通用，认准 `.espdl`。
2. **工具包与库版本要配套**。官方注记的例子：P4 的 per-channel 量化需要 esp-ppq ≥ 1.2.10 **且** esp-dl ≥ 3.3.1。S3 用不到这条，但规律通用；另外**模型不跨芯片**——量化输出绑定目标（S3 与 P4 的量化策略不同，见 19.2 表），换芯片要重量化。

---

## 19.4 ESP-NN：算子层的加速器，以及加速到底发生在哪一层

ESP-NN 自我定位（README 原话）是"a library containing optimised NN functions for various Espressif chips"——**底层数值算子库**：卷积、深度卷积、池化、全连接、激活、逐元素加、softmax 的 int8 实现，按芯片分发手写汇编版。

它与 esp-dl 的关系要如实说：**esp-nn 的 README 把集成点写在 TFLite Micro 一侧**（配合 esp-tflite-micro，基准用 TFLite 的 `invoke()` 跑），而**当前 esp-dl 的 README 已不再提及 esp-nn**，`operator_performance.md` 只对比"ANSI C vs SIMD 优化版"。esp-dl 当前 kernel 是否直接复用 esp-nn 代码，官方文档未说明——**待核对**。可确定的是二者同构：都是把 C 参考实现换成吃向量指令的汇编。

esp-nn README 的 S3 单算子加速比（tick，240MHz / QPI 80MHz / 64KB cache，ANSI C → 优化版）：

| 算子                               | ANSI C  | 优化版 | 加速比 |
| ---------------------------------- | ------- | ------ | ------ |
| conv，输入 10×10，filter 64×1×1×64 | 4712500 | 331008 | 14.24× |
| conv，输入 8×8，filter 16×1×1×16   | 312754  | 39022  | 8.01×  |
| conv，输入 8×8，filter 64×3×3×3    | 2193289 | 394842 | 5.55×  |
| depthwise conv 1×3×3×16            | 1159831 | 184176 | 6.30×  |
| depthwise conv 8×5×5×4             | 1671363 | 372435 | 4.49×  |
| max pool                           | 376294  | 48069  | 7.83×  |
| fully connected（len 271, ch 3）   | 8443    | 1078   | 7.83×  |
| PReLU / relu6                      | 1125    | 98     | 11.48× |
| softmax                            | 15209   | 11107  | 1.37×  |

同一文档的 Person Detection（INT8）跨芯片对照，把"S3 的向量指令值多少钱"钉死：

| 芯片 @ 频率       | 无优化 | 优化后                   |
| ----------------- | ------ | ------------------------ |
| ESP32-S3 @ 240MHz | 2300ms | 54ms（内部 RAM 版 47ms） |
| ESP32-P4 @ 360MHz | 1395ms | 73ms                     |
| ESP32 @ 240MHz    | 4084ms | 380ms                    |
| ESP32-C3 @ 160MHz | 3355ms | 426ms                    |

注意 softmax 只有 1.37×：访存/查表密集、吃不满向量宽度的算子就是加速不动——这个分布本身就是"向量指令擅长什么"的答案。

**一句汇编级的洞察（本地实地核实）**：翻了 ESP-IDF v6.0.2 的 `components/xtensa/`（含 `esp32s3/include/xtensa/config/` 整套配置头），**没有任何向量指令的 intrinsic 或汇编宏**——grep `EE.V`/`vld`/`vip` 一无所获。也就是说，S3 的向量指令在 IDF 里没有"官方内建函数"，加速只发生在**库作者手写的 `.S` 汇编文件**里（esp-nn/esp-dl 的 kernel 源码层）。编译器不会替你自动向量化，`-O3` 也救不了 C 写的逐元素循环——这就是必须用这些库、而不是自己写 for 循环的根本原因。

顺带一个调试技巧（esp-nn README）：menuconfig 里有 `ESP-NN → NN_OPTIMIZATIONS`，可切回 **ANSI C 参考实现**；怀疑优化算子有 bug 时，用它做对照组二分定位。

---

## 19.5 官方示例导读：human_face_detect

esp-dl 的模型库（`models/`，每个模型是一个 ESP-IDF 组件，经 `idf_component.yml` 引入；模型库 README 另有 YOLO26、COCO 检测/姿态/分割、猫狗手部检测、MobileNetV2 分类、行人检测等）里与人脸相关的是 Human Face Detect（MSR/MNP/ESPDet，官方标注支持 ESP32-S3/S31/P4）。

**两级流水（MSR + MNP）**——便宜的先跑，贵的只跑候选：

```text
整幅图像 ──► msr_s8_v1（输入 120×160×3，扫全图出候选框）
                 │ 每个候选框抠出、缩放到
                 ▼
            mnp_s8_v1（输入 48×48×3，逐候选精修）
```

另有单级的 espdet_pico 系列。四个模型的输入与耗时拆解（出处：esp-dl `models/human_face_detect/README.md`，master，2026-08-26 抓取；耗时毫秒；精度为官方自建验证集上的 mAP50-95）：

| 模型                | 输入 (h×w×c) | S3 前处理 | S3 推理 | S3 后处理 | P4 推理 | mAP50-95              |
| ------------------- | ------------ | --------- | ------- | --------- | ------- | --------------------- |
| msr_s8_v1           | 120×160×3    | 3.8       | 33.1    | 0.3       | 13.1    | 0.367（msr+mnp 级联） |
| mnp_s8_v1（每候选） | 48×48×3      | 0.6       | 5.8     | 0.1       | 2.4     | 同上                  |
| espdet_pico_224     | 224×224×3    | 7.2       | 131.6   | 0.8       | 49.6    | 0.504                 |
| espdet_pico_416     | 416×416×3    | 21.8      | 437.0   | 1.3       | 185.9   | 0.598（P4 上 0.597）  |

读表三个观察：

1. **推理列才是模型本身的账**，官方前处理+后处理相加不到 10%（输入小、后处理就几个阈值比较）。但你自己接摄像头时，像素格式转换/缩放常常反超模型本身——这笔账官方表里没有，要自己量。
2. **两级结构是算力分配的教科书**：全图只花 33ms 出候选，重模型 MNP 只对每个 48×48 候选花 5.8ms；对比单级 espdet_416 一次 437ms——先粗后精，同一颗 CPU 的两套预算。第二十章若做"人脸门控"，选的就是这套两级模型。
3. **模型文件体积官方未给字节数**（该 README 只说分区要"装得下模型文件"）——**待核对**（拿到模型组件目录后实际称重）。

再一次，示例的板型支持印证 19.1 的边界：esp-who 的 human_face_recognition 示例只带了 S3-EYE / Korvo-2 / P4 三套 `sdkconfig.bsp.*`，没有 BOX-3。esp-who README 同时说明：它"developed based on ESP-DL"，摄像头驱动另归 esp32-camera / esp-video-components，且"camera and model now runs asynchronously, which achieves higher fps"——采帧与推理分任务异步，正是 19.6 要展开的工程姿势。

---

## 19.6 部署到推理任务的工程学

模型文件有了，剩下两件工程决策：**模型放哪、推理放在哪个任务里**。

### 1. 模型放哪：三种加载方式（出处：官方教程 `how_to_load_test_profile_model.rst`）

| 方式                  | 分区表 / 构建动作                                                                             | 加载代码                                                                        | 适用                                         |
| --------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------- |
| 编进 app 的 `.rodata` | `set(embed_files ...)` + `target_add_aligned_binary_data(${COMPONENT_LIB} ... BINARY)`        | `new dl::Model((const char *)model_espdl, fbs::MODEL_LOCATION_IN_FLASH_RODATA)` | 小模型；缺点是改代码也要重烧模型             |
| 独立 model 分区       | 分区表加 `model, data, spiffs, , 4000K,` + `esptool_py_flash_to_partition(flash "model" ...)` | `new dl::Model("model", fbs::MODEL_LOCATION_IN_FLASH_PARTITION)`                | 大模型；`idf.py app-flash` 只烧 app 不动模型 |
| SD 卡（FAT32）        | 挂载文件系统（`bsp_sdcard_mount()`）                                                          | `new dl::Model("/sdcard/model.espdl", fbs::MODEL_LOCATION_IN_SDCARD)`           | 免烧录换模型                                 |

`.rodata` 方式引用的是链接器生成符号（`_binary_` + 文件名 + `_start`）：

```cpp
extern const uint8_t model_espdl[] asm("_binary_model_espdl_start");
```

眼熟吗——`model, data, spiffs` 这一行，与 [[ch4-project-anatomy|第四章]] factory_demo 分区表里那个 8600K 的 `model` 分区（esp-sr 语音模型的住户）是同一个模式：**边缘 AI 设备的 Flash 布局里，"模型分区"是一等公民**，esp-sr 与 esp-dl 在这里殊途同归。

### 2. 张量放哪：PSRAM 与内部 SRAM 的取舍

`dl::Model` 的高级构造参数把这个决策做成了旋钮（同上教程）：

| 参数                | 语义                               | 默认取向                                |
| ------------------- | ---------------------------------- | --------------------------------------- |
| `max_internal_size` | 内部 RAM 用量上限（如 `0` = 不用） | 让库自己把"热"张量搬进内部 RAM          |
| 内存管理策略        | 如 `dl::MEMORY_MANAGER_GREEDY`     | 静态内存规划器统一排布                  |
| `param_copy`        | 是否把参数从 Flash 拷进 RAM        | `true`（换速度）；`false` 省 RAM 但更慢 |

为什么要抠这个：19.2/19.4 的官方基准全部跑在"Octal PSRAM + 64KB cache"上，cache 命中主导访存延迟——**同一模型，张量挪进内部 RAM 就有可见的整模型收益**（esp-nn README 的 Person Detection：ESP32-S3 上 54ms，张量用内部 RAM 的版本 47ms）。S3 内部 SRAM 总共 512KB 级，还要养 FreeRTOS 堆、LVGL、音频 DMA，不可能全塞进去。caps 分配的底层机制（`MALLOC_CAP_INTERNAL` vs `MALLOC_CAP_SPIRAM`、各池怎么来的）见 [[ch20-idf-heap-and-caps|FreeRTOS 深度解析（二十）]]，此处只取工程结论：

| 内存池    | 放什么                                                      |
| --------- | ----------------------------------------------------------- |
| 内部 SRAM | 被双核调度反复读写的中间张量、算子的工作缓冲                |
| PSRAM     | 模型参数（`param_copy` 的目的地）、大输入帧、冷张量         |
| Flash     | `.espdl` 原文件（model 分区或 `.rodata`），推理时不占用 RAM |

调参依据不是猜，是 profile：`model->profile_memory()` 按 `fbs_model / parameter_copy / variable / others / total` 分类、并按**内部 RAM / PSRAM / Flash** 三个池分别打印用量。

### 3. 推理放哪个任务：与第十八章同构

第十八章讨论过的"推理任务的实时性与内存开销"结论在这里原样适用，换成视觉版管线：

```text
采帧任务（摄像头驱动/esp-camera） ──帧队列──► 前处理（缩放/格式转换/量化到 int8）
                                                    │
                                                    ▼
                                        推理任务：dl::Model::run()
                                                    │ 结果队列
                                                    ▼
                                        业务/UI 任务（LVGL 框选、红外触发）
```

- **独立任务，别共享**。`run()` 一次几十到几百毫秒（19.5 的表），绝不能塞进音频回调、ISR 或任何有截止时间的路径；高优先级任务里跑长推理还会喂任务看门狗（第十三章的老话题）。
- **绑核**。esp-dl runtime 支持 Conv2D/DepthwiseConv2D 的**双核调度**（README 事实）——推理任务按第十八章的分工惯例让出 Core 0（协议栈/音频），让库自己把算子摊到空闲核上。
- **喂帧用队列，别共享缓冲**。官方教程明示：esp-dl 为每个模型只分配**一块共享内存**（输入/中间/输出张量共住），"推理时后算的结果会覆盖先算的结果"——推理完成后你的输入数据可能已被输出覆盖。帧数据要 `assign` 进模型张量，推理完立刻取走输出，缓冲所有权必须清晰。

---

## 19.7 实验：在 PC 上完成一次量化（方法论级）

> [!note] 诚实声明
> 以下 PC 侧步骤摘自 esp-dl 官方教程（`how_to_quantize_model.rst` / `how_to_run_model.rst`，master，2026-08-26 抓取），本文成稿时**未逐一执行**，命令与产物以官方教程为准；不编造任何终端输出。

1. **装工具包**：按 19.3 的两条 pip 命令装 esp-ppq（含 CPU 版 torch）。
2. **准备模型与校准数据**：教程用 `sin_model.py` 训练一个拟合正弦的小网络，保存 `.pth` 并导出 ONNX——真实模型同理：PyTorch 导 ONNX，TF/Paddle 先转 ONNX。校准数据要**覆盖真实输入分布**，这是 PTQ 精度的生命线。
3. **写量化脚本**：调 `espdl_quantize_onnx` / `espdl_quantize_torch`；关键选项 `export_test_values`（把一对测试输入/输出嵌进 `.espdl`，板上 `model->test()` 靠它对答案）；测试输入 `input_shape`（随机生成）与 `inputs`（指定张量）二选一；只支持 batch_size=1。
4. **检视产物**：三件套（19.3 表）；`.info` 里的 test inputs/outputs value 是后续排错的金标准。
5. **PC 端评估量化精度**：量化 API 返回 `BaseGraph`，包成 `TorchExecutor` 直接在 PC 上推理量化模型——官方明确"板上结果与 esp-ppq 对齐"，所以精度指标 PC 上算就行，**不用反复烧板**：

```python
executor = TorchExecutor(graph=quanted_graph, device=device)
output = executor(input)
```

6. **板上验证**（不依赖摄像头：`model->test()` 只需嵌入的测试值）：

> [!warning] 待真机验证
> 前置条件：esp-dl 组件加入工程（`idf_component.yml` 引入模型组件，或自备 `.espdl` 按三种方式之一加载）。预期：`model->test()` 返回 `ESP_OK` 表示板上输出与 PC 侧一致（INT16 模型容差 ±1）；`model->profile_module()` 拿逐层延迟（可按耗时排序），`model->profile_memory()` 拿三池内存分布。摄像头路径（DOCK 外接模组 + esp-camera 采帧 → 前处理 → 推理 → 结果上屏）无官方 BOX-3 支持，连线、驱动、帧率均待真机验证。

实验记录（真机到货后补）：

| 步骤                   | 现象/输出 |
| ---------------------- | --------- |
| pip 安装 esp-ppq       | 待补      |
| sin 模型量化产物三件套 | 待补      |
| TorchExecutor 精度对比 | 待补      |
| 板上 `model->test()`   | 待补      |

---

## 19.8 翻车点表与小结

| 症状                          | 根因                                                                              | 处理                                                                                                                                      |
| ----------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| 量化后精度暴跌                | PTQ int8 对分布敏感；校准数据不覆盖真实输入                                       | 先用 TorchExecutor 在 PC 上评估量化模型（19.7 步骤 5）；仍不够则走官方 QAT/TQT 路线（`quantize_model_with_TQT.rst`、YOLO11n-pose QAT 例） |
| PC 上对、板上输出全错         | 输入归一化/前处理与训练管线不一致（均值方差、RGB/BGR、缩放）                      | 前处理逐项复刻训练管线；用 `.info` 的 test inputs value 喂同样数据做二分                                                                  |
| 推理比官方数字慢一个量级      | 张量落在 PSRAM 吃 cache miss；或 `param_copy=false`                               | `profile_memory()` 看三池分布，调 `max_internal_size`；确认 `param_copy` 默认开                                                           |
| 编译/加载报格式或符号错       | 新旧流程混用：v1.x 的 .cpp/.h 配新版 esp-dl，或反之；esp-ppq 与 esp-dl 版本不配套 | 统一走 `.espdl` + esp-ppq 新流程；工具包与库配套升级（19.3）                                                                              |
| 唤醒词/音频卡顿甚至 TWDT 复位 | 推理塞进音频任务或高优先级路径，一次几十~几百 ms                                  | 独立推理任务 + 队列喂帧（19.6 第 3 节），与第十八章同构                                                                                   |
| 推理完读输入缓冲，数据变了    | esp-dl 单块共享内存，输出会覆盖输入（官方明示）                                   | 输入先 `assign` 进模型张量；输出推理后立即取走，不持有内部指针                                                                            |
| 烧录后模型分区报错/装不下     | 分区表没加 model 分区或容量不足                                                   | `model, data, spiffs, ...` 一行 + `esptool_py_flash_to_partition`；开发期用 `idf.py app-flash` 免重烧模型                                 |
| BOX-3 上想直接跑 esp-who 示例 | 示例无 BOX-3 板型支持（只有 S3-EYE/Korvo-2/P4）                                   | 要么换板，要么走 DOCK 外接摄像头自行移植（待真机验证）                                                                                    |

本章小结：

- **边界先于内容**：BOX-3 无摄像头，本章交付的是"模型部署到 S3"的通用方法论；视觉实操要么 DOCK 外接摄像头（待真机验证）要么换 S3-EYE；第二十章综合项目不依赖本章。
- **量化是入场券**：S3 没有浮点加速，向量指令面向 int8——官方数据：单算子 SIMD 加速比 13.9×~77.5×（operator_performance.md），整模型 Person Detection 2300ms→54ms（esp-nn README），全部注明测试条件。
- **工具链一句话版**：训练框架 → ONNX → **esp-ppq**（PTQ 8/16bit）→ **`.espdl`**（FlatBuffers）→ 板上 `dl::Model` 三种加载方式（rodata / 分区 / SD 卡）之一 → `run()`；别再按旧教程找 .cpp/.h。
- **加速发生在手写汇编层**：IDF 的 xtensa 头文件里没有向量指令 intrinsic（本地核实），esp-nn/esp-dl 的 `.S` 文件才是加速的实体；menuconfig 可切 ANSI C 对照调试。
- **工程学三板斧**：模型进独立分区（与 ch4 的 esp-sr model 分区同一模式）；热张量进内部 RAM（`max_internal_size` 旋钮 + `profile_memory()` 证据）；推理独立任务 + 队列喂帧，警惕共享内存覆盖。

下一章把全系列收口：唤醒 → 命令识别 → LVGL 反馈 → 红外发射的语音遥控器，任务/优先级/内存设计的全部账本在那里对总——本章的 ESP-DL 若被选作扩展线，也将在那里挂接。

---

> [!info] 素材核实说明
> 本章 GitHub 素材（esp-dl master：README、`operator_performance.md`、`models/README.md`、`models/human_face_detect/README.md`、`docs/en/tutorials/how_to_quantize_model.rst`、`how_to_run_model.rst`、`how_to_load_test_profile_model.rst`、仓库目录（GitHub API）；esp-nn master：README；esp-who master：README、examples 目录）均于 2026-08-26 经 WebFetch 逐页核实；ESP-IDF 侧事实（xtensa 组件无向量指令 intrinsic）为本地 v6.0.2 源码实地 grep。未核实到的数字一律标「待核对」。
