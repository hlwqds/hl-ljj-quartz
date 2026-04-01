---
title: Claude Code 通知声音配置与 TTS 探索
date: 2026-03-29 12:00:00
tags: [claude-code, tts, edge-tts, ChatTTS, Spark-TTS, hooks, linux]
---

## 概述

为 Claude Code 配置了交互通知声音，探索了多种 TTS 方案，最终采用 **Spark-TTS 0.5B** 作为通知语音方案。

## 最终方案：Spark-TTS 0.5B

- **TTS 引擎**：Spark-TTS 0.5B（Apache 2.0）
- **声模参数**：`--gender female --pitch low --speed low`（温柔低沉慵懒风格）
- **文本**：`主人，请确认一下`
- **运行环境**：conda `sparktts` (Python 3.12)，代码位于 `/tmp/Spark-TTS`
- **CPU 推理时间**：约 8 分钟/句（无 GPU 加速）

### 生成命令

```bash
cd /tmp/Spark-TTS && conda run -n sparktts python3 -m cli.inference \
  --text "主人，请确认一下" \
  --gender female --pitch low --speed low \
  --save_dir /tmp/spark_output \
  --model_dir pretrained_models/Spark-TTS-0.5B

# 转换为 mp3
ffmpeg -y -i /tmp/spark_output/*.wav -codec:a libmp3lame -qscale:a 2 \
  ~/.claude/notify-confirm.mp3
```

### 安装记录

```bash
sudo dnf install conda
conda create -n sparktts python=3.12 -y
git clone https://github.com/SparkAudio/Spark-TTS.git /tmp/Spark-TTS
cd /tmp/Spark-TTS
conda run -n sparktts pip install -r requirements.txt
# 模型会自动下载到 pretrained_models/Spark-TTS-0.5B
```

## Claude Code Hooks 配置

在 `~/.claude/settings.json` 中配置了两个 hook：

- **Notification hook**：Claude 需要用户确认时触发
- **Stop hook**：Claude 完成任务停止时触发

两个 hook 都执行 `paplay ~/.claude/notify-confirm.mp3 2>/dev/null &`，后台播放通知音频。

## TTS 方案对比

| 方案                 | 效果             | CPU 速度    | Py 3.14     | 结果         |
| -------------------- | ---------------- | ----------- | ----------- | ------------ |
| espeak-ng            | 机械感太强       | 秒级        | 兼容        | 不采用       |
| edge-tts (Microsoft) | 自然但不够色气   | 秒级        | 兼容        | 备选         |
| ChatTTS (本地)       | 情感丰富         | 5-10 分钟   | 兼容        | 男声问题     |
| MiniMax TTS API      | 不可用           | -           | -           | 订阅不含 TTS |
| **Spark-TTS 0.5B**   | **温柔低沉女声** | **~8 分钟** | **需 3.12** | **采用**     |

## edge-tts 中文女声清单

edge-tts 可用的中文女声（降调参数可调慵懒感但有限）：

| Voice ID              | 风格            |
| --------------------- | --------------- |
| zh-CN-XiaoxiaoNeural  | 温暖，新闻/小说 |
| zh-CN-XiaoyiNeural    | 活泼，卡通/小说 |
| zh-TW-HsiaoChenNeural | 友好，台普      |
| zh-TW-HsiaoYuNeural   | 友好，台普      |
| zh-HK-HiuGaaiNeural   | 友好，粤语      |
| zh-HK-HiuMaanNeural   | 友好，粤语      |

### edge-tts 调参技巧

降调减速营造慵懒感（效果有限）：

```bash
python3 -m edge_tts --voice zh-CN-XiaoxiaoNeural \
  --rate="-20%" --pitch="-50Hz" \
  --text "主人，请确认一下" \
  --write-media output.mp3
```

## ChatTTS 排坑记录

- **环境**：Python 3.14 + PyTorch 2.11，Fedora 43
- **transformers 兼容性**：需降级到 `transformers<4.50`（4.49.0），否则 `BertTokenizer` 报错
- **soundfile 依赖**：需单独安装
- **文本限制**：不支持全角波浪号 `～` 和日文字符，中文内容正常
- **Intel GPU**：有 Arc Pro 130T/140T，但 IPEX 不兼容 Python 3.14 + PyTorch 2.11，只能 CPU 推理（5-10 分钟/次）
- **男声问题**（未解决）：尝试了多种方案仍生成男声
- **可能的解决方案**（未尝试）：
  - `chat.sample_audio_speaker(path_to_female_audio.mp3)` 从女声样本克隆
  - 预设女声 speaker embedding (.npy 文件)
  - [ChatTTS_Speaker](https://github.com/6drf21e/ChatTTS_Speaker) 项目提供 2000+ 预标注声模

## CLAUDE.md 配置

添加了称呼偏好：所有交互中称呼用户为"主人"。
