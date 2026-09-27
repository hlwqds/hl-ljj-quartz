# pll-4046-breadboard —— 分立 PLL 面包板实验(ch00e 配套·纯硬件支线)

对应章节:[[ch00e-clock-tree-and-systick-silicon|时钟树与 SysTick 章]]——把那一节时钟树图里
抽象的「PLL 倍频器」方框,拆成面包板上看得见摸得着的五个部件(浏览页里 `[[wikilink]]`
是纯文本,该笔记即仓库的 `content/f429-lab/ch00e-clock-tree-and-systick-silicon.md`)。
系列总目录:[[f429-lab|F429 裸机实验室]]。

ch00e 里 PLL 是一个名字;本工程用 74HC4046(鉴相 + VCO)+ 74HC4040(÷N 分频反馈)
搭一个真的:32.768kHz 参考(与板上 LSE 同频)→ 鉴相 → RC 环路滤波 → VCO → ÷16 反馈,
锁定出 524.288kHz。**改一根跳线 = 改倍频配置;调偏 VCO 频段 = 亲眼看失锁;加大环路
电容 = 看慢收敛**——第 3/4/5 步分别把 M/N/P、CSS 失锁兜底、片内环路滤波从寄存器
黑盒里拖到实体(第 6 步为进阶选做:HSE bypass,见教程第 7 节)。

> 状态:**先成文、后实跑**——零件在途。管脚表已按三家厂商 datasheet 对拍(见教程),
> 全部「预期输出」待实测后回填本 README 与章节。

## 链路图

```text
                     ┌──────────────── 74HC4046 ────────────────┐
 32.768kHz 有源晶振   │                                           │
 ──OUT──► SIGIN(14)──┤►PC2 鉴相器◄────────────── COMPIN(3) ◄──┼── 4040 Q4(脚5,÷16)
            PC2OUT(13)┤                                           │      (反馈跳线 J1)
                │     │  R1(11)─10k─GND   R2(12)─10k─GND         │
                ▼     │  C1: 脚6─470pF─脚7(起步档,频段待扫频定)  │ VCOOUT(4) ──► TP1 测试点
              R3 100k │  INH(5)─GND(必须!)                      │        └──► 4040 CP(脚10)
                │     │                                           │           MR(脚11)─GND(必须!)
                ▼     └───────────────────────────────────────────┘
           节点 A = VCOIN(9) ──┬── C2 100nF ── GND(环路滤波,τ=10ms)
                               └──(开环时)10k 电位器滑臂跳线
 供电:树莓派排针 物理脚1(3V3)→红轨、脚9(GND)→地轨;全案 3.3V,预期 <20mA
```

完整接线表、六步实验、调试分诊表见
[docs/tutorial.md](/static/code/#/f429-lab/pll-4046-breadboard/docs/tutorial.md)。

## 频率算术

| N(反馈点) | 4040 输出脚 | VCO 锁定频率 | 测量手段                              |
| --------- | ----------- | ------------ | ------------------------------------- |
| 16(Q4)    | 脚 5        | 524 288 Hz   | 频率计 @Q4 直读 32768Hz,×16 还原      |
| 32(Q5)    | 脚 3        | 1 048 576 Hz | 频率计 @Q5 ×32;VCO 直测需 LA          |
| 64(Q6)    | 脚 2        | 2 097 152 Hz | 频率计 @Q6 ×64;VCO 直测需 LA(24MSa/s) |

**精确测频一律在 4040 的 Q 输出上做、读数 ×2ⁿ 还原**:pigpio 1µs 档可靠检测的边沿
上限约 500kHz,524kHz 的 VCOOUT 直测会混叠欠读、N≥32 直接超出(详见
[docs/instruments.md](/static/code/#/f429-lab/pll-4046-breadboard/docs/instruments.md) §3)。
反馈点恒为 32.768kHz:SIGIN 与 COMPIN 的**相位对齐**观察任何 N 档下都在 piscope 能力内。

## 元件清单(BOM)

| 元件           | 规格                                                             | 数量 | 参考价 | 购买关键词                       |
| -------------- | ---------------------------------------------------------------- | ---- | ------ | -------------------------------- |
| PLL 芯片       | 74HC4046N,DIP-16                                                 | 1    | ¥3     | `74HC4046N DIP`                  |
| 分频计数器     | 74HC4040N,DIP-16                                                 | 1    | ¥1.5   | `74HC4040N DIP`                  |
| 有源晶振(钟振) | 32.768kHz,DIP 封装,**3.0~3.6V 供电档**                           | 1    | ¥3     | `32768Hz 有源晶振 DIP 3.3V`      |
| 电位器         | 10k,3296W 微调或 RV09 旋钮                                       | 1    | ¥1     | `3296W 10k`                      |
| 电阻           | 100Ω×1、100k×1、10k×3、1k×2,1/4W                                 | 若干 | ¥8     | `1/4W 电阻包 常用值`             |
| 瓷片电容       | 470pF(472)×3、220pF(221)×2、1nF(102)×3、100nF(104)×4、1µF(105)×1 | 若干 | ¥6     | `瓷片电容包 472 221 102 104 105` |
| 面包板         | 830 孔                                                           | 1    | ¥8     | `面包板 830`                     |
| 杜邦线         | 公对公 + 公对母(接 Pi 排针)各 20 根                              | 1 组 | ¥10    | `杜邦线 面包板 公对公 公对母`    |
| LED            | 3mm 任意色                                                       | 2    | ¥0.5   | `3mm LED`                        |
| IC 插座        | DIP-16                                                           | 2    | ¥1     | `DIP-16 圆孔插座`                |
| 微调螺丝刀     | ~2.5mm 一字(配 3296W 调节孔)                                     | 1    | ¥2     | `钟表螺丝刀 一字 小`             |

合计约 ¥44(不含树莓派/万用表)。**用量对账**(接线表实耗 vs 上表数量):10k×2
(R1/R2)、1k×1(LED 限流)、LED×1、470pF×1(C1)、100nF×3(去耦×2 + C2)、1µF×1
(第 5 步 C2)、100Ω×1(第 7 步 HSE bypass,选做)——10k 第 3 颗、1k 第 2 颗、
LED 第 2 颗、100nF 第 4 颗、1nF×3、220pF×2 均为**备件**(烧坏/误焊即换)或换档
备选,不是漏写了用途。
**有源晶振引脚定义随厂商**(常见 1=NC、2=GND、3=OUT、4=VCC,**待核对**——以实物
datasheet 为准,到货核对三步见教程 §1.3);供电电压档务必选 3.3V 兼容版。

## 购买链接(淘宝关键词直达)

商品页链接易失效(下架/改价常态),以下给**关键词直达搜索页**——点开即筛选好的结果,
选销量高、评价好的店铺下单。下单前必看 BOM 表注记:晶振必选 **3.3V 供电档**(5V 版
跑 3.3V 不起振)、两颗芯片认准 **DIP 直插**(别买 SOP 贴片)、易损小件按下表冗余量买。

| 元件          | 淘宝直达                                                                                                                                                                                                    |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 74HC4046N     | [搜索 74HC4046](https://s.taobao.com/search?q=74HC4046+DIP)                                                                                                                                                 |
| 74HC4040N     | [搜索 74HC4040](https://s.taobao.com/search?q=74HC4040+DIP)                                                                                                                                                 |
| 有源晶振 3.3V | [搜索 32.768K 有源晶振](https://s.taobao.com/search?q=%E6%9C%89%E6%BA%90%E6%99%B6%E6%8C%AF+32.768K+DIP+3.3V)                                                                                                |
| 3296W 电位器  | [搜索 3296W 10K](https://s.taobao.com/search?q=3296W+10K)                                                                                                                                                   |
| 电阻包        | [搜索 1/4W 电阻包](https://s.taobao.com/search?q=1%2F4W+%E7%94%B5%E9%98%BB%E5%8C%85)                                                                                                                        |
| 瓷片电容包    | [搜索 瓷片电容包](https://s.taobao.com/search?q=%E7%93%B7%E7%89%87%E7%94%B5%E5%AE%B9%E5%8C%85+102+104)                                                                                                      |
| 面包板 830 孔 | [搜索 面包板 830](https://s.taobao.com/search?q=%E9%9D%A2%E5%8C%85%E6%9D%BF+830)                                                                                                                            |
| 杜邦线        | [搜索 公对公](https://s.taobao.com/search?q=%E6%9D%9C%E9%82%A6%E7%BA%BF+%E5%85%AC%E5%AF%B9%E5%85%AC) / [搜索 母对母](https://s.taobao.com/search?q=%E6%9D%9C%E9%82%A6%E7%BA%BF+%E6%AF%8D%E5%AF%B9%E6%AF%8D) |
| 3mm LED       | [搜索 3mm LED](https://s.taobao.com/search?q=3mm+LED+%E7%9B%B4%E6%8F%92)                                                                                                                                    |
| DIP-16 插座   | [搜索 DIP16 芯片座](https://s.taobao.com/search?q=DIP16+%E8%8A%AF%E7%89%87%E5%BA%A7)                                                                                                                        |
| 钟表螺丝刀    | [搜索 一字钟表螺丝刀](https://s.taobao.com/search?q=%E9%92%9F%E8%A1%A8%E8%9E%BA%E4%B8%9D%E5%88%80+%E4%B8%80%E5%AD%97)                                                                                       |

## 目录结构

| 文件                    | 说明                                                           |
| ----------------------- | -------------------------------------------------------------- |
| `README.md`             | 本文件:定位、链路图、BOM、复现入口                             |
| `docs/tutorial.md`      | 实验教程:管脚速查表、接线表、六步实验、调试分诊、HSE bypass    |
| `docs/instruments.md`   | 仪器指南:万用表/频率计/piscope/LA 三档分工与锁定判据、ppm 换算 |
| `results/RESULTS.md`    | 实测记录表:六步逐格(数值+仪器+命令)+ 供核对项销账              |
| `tools/measure_freq.py` | 树莓派 pigpio 频率计(边沿计数+闸门,Q 输出直测 ×2ⁿ 还原)        |

本工程是 f429-lab 的**纯硬件支线**,无固件源码(SPEC 的裸机骨架由
[rcc-uart-read](/static/code/#/f429-lab/rcc-uart-read/README.md) 承担);第 6 步
HSE bypass 实测时复用其 Makefile/startup,只改 clock_init。

## 站内代码浏览页

- [完整工程 README](/static/code/#/f429-lab/pll-4046-breadboard/README.md)
- [实验教程 docs/tutorial.md](/static/code/#/f429-lab/pll-4046-breadboard/docs/tutorial.md)
- [仪器指南 docs/instruments.md](/static/code/#/f429-lab/pll-4046-breadboard/docs/instruments.md)
- [实测记录表 results/RESULTS.md](/static/code/#/f429-lab/pll-4046-breadboard/results/RESULTS.md)
- [GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/tree/v4/practice/f429-lab/pll-4046-breadboard)

## 已知边界(先成文的诚实账)

- VCO 起步档按 datasheet 定量锚点选取:f0≈2.0/(R1·C1)(Nexperia 74HC4046A Rev.7:
  17MHz typ @VCC=4.5V、R1=3kΩ、C1=40pF)。照此 1nF/10k 档 f0≈200kHz@4.5V、3.3V 更低,
  频段上界 <2×f0,锁不到 524.288kHz——故起步 C1=470pF(f0≈425kHz@4.5V),3.3V 实测
  频段若仍覆盖不到再换 220pF;频段上下限一律以第 1 步实测扫频为准(待实测核销);
- HSE bypass 的输入频率下限以 F429 datasheet 为准(**待核对**,教程第 6 步有算术);
- 一切管脚号带厂商核对状态列,买到芯片先读丝印、下对应 datasheet 对一遍再用。
