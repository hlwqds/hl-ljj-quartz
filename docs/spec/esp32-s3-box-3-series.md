# Spec: ESP32-S3-BOX-3 工程实战系列——首批初稿（ch1~ch20）

- 状态：**初稿全量完成**（2026-08-26）。20/20 章落盘，验收契约六项全过：
  命名 20/20、frontmatter 4/4 全通过、「待真机验证」ch1=6/ch5=5 处、
  索引 ✍️ 20 行、wikilink 死链 0、行数 263~423（合计 7141 行）。
- 下一阶段：真机到货后按 KD-6/KD-7 定案清单逐项核销，实验/QEMU 输出回填，
  用户验收后状态改 ✅。
- 背景：系列索引已发布（`content/2026-08-26-esp32-s3-box-3-hands-on-series-index.md`，20 章规划）。
  本迭代交付全部 20 章初稿。硬件（BOX-3 标准版）在途，真机依赖步骤以
  「待真机验证」显式标注，到货后边实验边修订。

## Goals（本迭代）

- 交付 **ch1~ch20 全部 20 章初稿**（2026-08-26 用户扩大范围：当日全部完成），
  文件位于 `content/`，风格与既有系列一致。
- 凡是能在本机（无硬件）验证的命令与事实，必须实际执行/核对后写入，引用真实输出；
  不得凭空编造终端输出。
- 每章与 FreeRTOS 深度解析系列的交叉引用准确（不重复教学，指向对应章节）。

## Non-goals（本迭代，及各自影响）

- 真机验证（flash/monitor/唤醒词体验/逻辑分析仪波形）：所有此类步骤标注
  「待真机验证」；初稿状态即 ✍️，不标 ✅。影响：ch1 的烧录段、ch5 的 esptool
  实操段、Part III 各章 L4 波形以命令+预期行为成稿，输出留空待补。
- 环境自动化（安装脚本/CI）：只记录手动步骤与排坑，不做工具化。
- esp-idf 双版本并存方案（v5.1/v6）的完整教程化：仅在 ch1 记录 factory_demo
  的版本约束事实与一种可行解法。

## 机制映射（参照实现 = 本仓库 FreeRTOS 深度解析系列）

参照物是同仓库的姊妹系列，写作约定全部对齐：

| 关注点     | FreeRTOS 系列                               | 本系列                                   |
| ---------- | ------------------------------------------- | ---------------------------------------- |
| 章节文件名 | `YYYY-MM-DD-freertos-deep-dive-chN-slug.md` | `YYYY-MM-DD-esp32-s3-box-3-chN-slug.md`  |
| 章首导航   | `> [!info]` 系列列表（索引+已发布章节）     | 同左，五章列表固定                       |
| 状态标记   | ✅ 已发布 / 📝 规划中                       | 增加第三态 ✍️ 初稿（待真机验证）         |
| 环境教学   | ch1 一次讲完 QEMU 环境                      | ch1 只讲增量（esp32s3 目标补装），不重复 |
| 平台口径   | QEMU 主线、真机对照                         | 真机主线、QEMU 可选对照                  |
| 实验证据   | QEMU 终端输出                               | 本机构建日志（真实）+ 真机段标注待验证   |

## 验收契约（每行含观察点）

- 5 个章节文件存在且命名符合 `2026-08-26-esp32-s3-box-3-ch*-*.md`
  → obs: `ls content/ | grep esp32-s3-box-3-ch`
- 每章 frontmatter 含 title/date(完整时分秒)/description/tags
  → obs: `head` 各文件逐项核对
- 含真机依赖步骤的章节出现至少一处 `待真机验证`
  → obs: `grep -c 待真机验证 content/2026-08-26-esp32-s3-box-3-ch*.md`（ch1、ch5 必须 >0）
- 系列索引表 ch1~5 行更新为 wikilink + ✍️ 状态
  → obs: `grep '✍️' content/2026-08-26-esp32-s3-box-3-hands-on-series-index.md` ≥5 行
- 所有 `[[wikilink]]` 目标文件存在（防死链）
  → obs: 对索引与五章中的每个 wikilink 名 grep 同名文件
- 已验证命令与真实构建日志一致（抽查 3 处）
  → obs: 构建日志存于 `~/esp/build-logs/`（scratch，不入库），文内引用可溯源
- 硬件事实（芯片型号/Flash/PSRAM/唤醒词/IDF 版本约束）与 esp-box 仓库、
  组件清单一致 → obs: 与 `~/esp/esp-box` 内文件比对（AHT20/AT581x/ILI9342C/
  FT6336/ES8311/ES7210、WN9 嗨乐鑫/Hi ESP、idf>=5.1）

## 验证计划（与证据来源绑定）

- 结构三项（命名/frontmatter/wikilink）：主会话统一跑脚本化检查（grep/ls），
  产出核对清单贴在迭代收尾总结。
- 命令真实性：factory_demo 构建由主会话单点执行（避免并发安装冲突），
  完整日志归档 `~/esp/build-logs/factory-demo-build.log`；ch1/ch5 的引用从中摘录。
- 风格一致性：每章对照 `content/2026-08-26-freertos-deep-dive-ch1-*.md`
  的段落密度、callout 用法、"翻车点"表格惯例——评审式检查（主会话抽查）。
- 终审：用户在真机到货、跑通实验后将状态改为 ✅（人为关卡，不由 agent 代标）。

## 章节命名与导航约定（全系列统一，子 agent 写作必须遵守）

文件名（`content/` 下）：

| #   | 文件名（不含 .md）                                   | 章标题                                      |
| --- | ---------------------------------------------------- | ------------------------------------------- |
| 1   | 2026-08-26-esp32-s3-box-3-ch1-quick-start            | 三十分钟跑通                                |
| 2   | 2026-08-26-esp32-s3-box-3-ch2-ecosystem-map          | 乐鑫开源生态与资料地图                      |
| 3   | 2026-08-26-esp32-s3-box-3-ch3-idf-toolchain          | idf.py 背后——工具链与命令面                 |
| 4   | 2026-08-26-esp32-s3-box-3-ch4-project-anatomy        | 工程解剖与组件体系                          |
| 5   | 2026-08-26-esp32-s3-box-3-ch5-image-and-flashing     | 编译产物与烧录链路                          |
| 6   | 2026-08-26-esp32-s3-box-3-ch6-boot-to-app-main       | 从上电到 app_main                           |
| 7   | 2026-08-26-esp32-s3-box-3-ch7-system-services        | 系统服务层：日志、NVS、事件循环与 esp_timer |
| 8   | 2026-08-26-esp32-s3-box-3-ch8-gpio-interrupts        | GPIO 与中断                                 |
| 9   | 2026-08-26-esp32-s3-box-3-ch9-i2c-sensors            | I2C 与传感器                                |
| 10  | 2026-08-26-esp32-s3-box-3-ch10-spi-display           | SPI 与屏幕                                  |
| 11  | 2026-08-26-esp32-s3-box-3-ch11-i2s-audio             | I2S 与音频                                  |
| 12  | 2026-08-26-esp32-s3-box-3-ch12-rmt-infrared          | RMT 与红外                                  |
| 13  | 2026-08-26-esp32-s3-box-3-ch13-timers-watchdogs      | 定时器与看门狗                              |
| 14  | 2026-08-26-esp32-s3-box-3-ch14-bsp-walkthrough       | esp-box-3 BSP 组件走读                      |
| 15  | 2026-08-26-esp32-s3-box-3-ch15-lvgl                  | LVGL                                        |
| 16  | 2026-08-26-esp32-s3-box-3-ch16-wifi-events           | WiFi 与 esp_netif                           |
| 17  | 2026-08-26-esp32-s3-box-3-ch17-rainmaker-matter      | 生态一瞥：RainMaker 与 Matter               |
| 18  | 2026-08-26-esp32-s3-box-3-ch18-esp-sr-wakeword       | ESP-SR 语音唤醒                             |
| 19  | 2026-08-26-esp32-s3-box-3-ch19-esp-dl-deployment     | ESP-DL 模型部署                             |
| 20  | 2026-08-26-esp32-s3-box-3-ch20-capstone-voice-remote | 综合项目：语音遥控器                        |

章首导航 callout 格式（ch6~ch20 用；ch1~ch5 由主会话终稿时统一归一到此格式）：

```markdown
> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[2026-08-26-esp32-s3-box-3-hands-on-series-index|系列索引]]
> 上一章：[[<prev-file>|第 N-1 章：<标题>]]
> **第 N 章：<本章标题>**（当前章）
> 下一章：[[<next-file>|第 N+1 章：<标题>]]
```

（ch1 无上一章；ch20 无下一章，该行写「系列完结」。）

## 任务拆分与扇出（process，迭代后可弃）

- 主会话（唯一写 `~/esp` 环境的角色）：esp-idf v6.0.2 克隆 → `install.sh esp32s3`
  → factory_demo 构建 → 归档日志 → 把真实输出喂给 ch1/ch5 写作 agent。
- 子 agent 批次 1（并行，仅读仓库+写 content/，禁跑构建）：ch2 生态地图、
  ch3 idf.py 工具链、ch4 工程解剖与组件体系。
- 子 agent 批次 2（依赖批次 1 无，依赖主会话构建产物）：ch1 快速上手、
  ch5 镜像与烧录链路。
- 主会话收尾：更新系列索引状态、跑验证契约、汇总。
