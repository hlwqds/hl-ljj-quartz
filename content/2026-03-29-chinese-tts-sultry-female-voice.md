---
title: 中文慵懒女声 TTS 方案调研
date: 2026-03-29 12:00:00
tags: [tts, voice-synthesis, chinese, ai-audio]
---

# 中文慵懒女声 TTS 方案调研

目标：生成一句约4秒的中文语音通知 "主人，人家需要你的确认哦"，要求声音温柔、低沉、慵懒/撒娇。
环境：Fedora 43, Python 3.14, Intel Arc GPU（IPEX 不兼容），仅 CPU。

## 方案对比总结

| 方案                | CPU可用 | Py3.14   | 语调控制            | CPU速度      | 安装难度   | 推荐度 |
| ------------------- | ------- | -------- | ------------------- | ------------ | ---------- | ------ |
| edge-tts (SSML调参) | YES     | YES      | pitch/rate/volume   | 即时         | pip        | ★★★★   |
| Spark-TTS 0.5B      | YES     | 3.12+    | gender/pitch/rate   | ~2-5秒/句    | conda+模型 | ★★★★   |
| Qwen3-TTS           | YES     | YES      | voice cloning       | ~2秒/句      | pip        | ★★★    |
| ChatTTS (spk_smp)   | YES     | YES      | speaker embedding   | 5-10分钟     | pip        | ★★     |
| GPT-SoVITS          | YES     | 3.9-3.11 | voice clone         | 很慢         | conda      | ★★     |
| CosyVoice           | YES     | 3.8-3.10 | emotion tags        | 很慢(10-50x) | conda+复杂 | ★★     |
| Fish Speech         | YES     | 3.8-3.10 | voice clone+emotion | 较慢         | clone+pip  | ★★     |
| Bark                | YES     | YES      | presets             | 极慢         | pip        | ★      |

## 最佳实践路径

**快速路径**：edge-tts + SSML prosody 调参（XiaomoNeural 或 XiaohanNeural，降pitch+降rate+narrow contour）
**高质量路径**：Spark-TTS 0.5B 提供参考音频做 zero-shot voice clone
