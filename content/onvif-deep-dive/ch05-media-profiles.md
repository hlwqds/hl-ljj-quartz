---
title: "ONVIF 深度解析（五）：Media Profile——配置三件套与 Media2 的简化"
date: 2026-10-10 12:00:00
description: "媒体配置模型解剖：MediaProfile 是引用的聚合体（VideoSourceConfiguration + VideoEncoderConfiguration + 可选 PTZ/Audio/Analytics 挂件，ReferenceToken 是唯一硬通货）；GetProfiles 响应逐块拆解；编码参数（分辨率/帧率/GovLength/码率上限）与 H.264/H.265 的取舍；先 Get 再 Set 的读改写纪律与 forcePersist；CreateProfile/AddConfiguration 动态拼装及其上限；Media2（tr2）合并服务族、扁平化配置模型的来龙去脉与新旧双栈并存的现实。"
tags: [onvif, media-profile, h264, h265, soap, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] 1. [[ch01-onvif-overview|第一章]] … 4. [[ch04-ws-security-auth|第四章]] 5. **第五章：Media Profile**

# ONVIF 深度解析（五）：Media Profile——配置三件套与 Media2 的简化

第四章结束时我们已经能通过摘要认证跟设备说上话，本章进入控制面的第一站"实活"：媒体配置——客户端怎么告诉一台摄像机"给我一路 1080p、H.264、25fps 的流"？ONVIF 把这件事的全部状态收拢在一个中心抽象里：**Media Profile**。本章依次回答：Profile 是什么（5.1）、怎么读一个 GetProfiles 响应（5.2）、编码参数各旋什么（5.3）、怎么安全地改（5.4）、怎么动态拼一个（5.5），最后看第二代媒体服务 Media2 如何把这套模型推倒重简（5.6）。

---

## 5.1 心智模型：Profile 是引用的聚合体

把 MediaProfile 想成**组装件而非容器**：它自己几乎不存任何媒体参数，只攥着一把 **ReferenceToken**（字符串句柄，设备分配、在设备内唯一；`Name` 是给人看的，token 才是给程序用的）。本章标题的"配置三件套"指三类组装件——源、编码器、可选挂件：

```text
MediaProfile（token=profile_1，name=mainstream）
├─ VideoSourceConfiguration   token=vsc_1
│     └─ SourceToken=vs_1 ──────▶ VideoSource（token=vs_1，物理传感器实体）
│     └─ Bounds：取景框 x/y/width/height（数字变焦 = 改它）
├─ VideoEncoderConfiguration  token=vec_1（H264 / 1920×1080 / 25fps / GOP=50）
├─ 可选挂件：AudioSourceConfiguration ─ AudioEncoderConfiguration（音频链）
│            PTZConfiguration（云台）/ MetadataConfiguration（元数据流）
│            AnalyticsConfiguration（智能分析）
└─ 客户端全流程只需要攥着 profile token：取流入参是它（ch06），PTZ 定位流也靠它（ch07）
```

| 配置件                                | 回答的问题         | 关键字段                                     |
| ------------------------------------- | ------------------ | -------------------------------------------- |
| VideoSourceConfiguration              | 从哪个传感器取画面 | SourceToken、Bounds                          |
| VideoEncoderConfiguration             | 画面怎么编码       | Encoding、Resolution、RateControl、GovLength |
| AudioSource/AudioEncoderConfiguration | 音频怎么取/怎么编  | SourceToken、Encoding、Bitrate               |
| PTZConfiguration                      | 云台默认行为       | NodeToken、默认速度/位置                     |
| MetadataConfiguration                 | 元数据流送什么     | PTZ 状态/事件/分析三类开关                   |

两个容易被新手错过、却决定后面所有操作姿势的语义：

- **配置实体有独立生命周期**。VideoEncoderConfiguration 不是 profile 的私有字段，而是独立实体——多个 profile 可以共享引用同一个编码配置 token，`UseCount` 字段就是引用计数。上图 `vsc_1` 若被主/子两个 profile 同时引用，改它的 Bounds 就是两个码流的取景框一起动（5.4 的坑）。
- **token 是整个媒体链路的索引键**。GetStreamUri 用 profile token 换 rtsp:// 地址，RTSP 会话、PTZ 控制同样以它定位——从发现（ch02）到取流（ch06），手里传来传去的始终是这种字符串句柄。

## 5.2 GetProfiles 响应解剖：从信封到取景框

动手前先找端点：媒体服务不在设备服务端点上，[[ch03-soap-services|第三章]]的 GetServices/GetCapabilities 会给出 media 服务的 XAddrs（典型形如 `http://192.168.1.64/onvif/media_service`）。GetProfiles 则是一个再普通不过的 SOAP 请求——媒体服务的命名空间是 `http://www.onvif.org/ver10/media/wsdl`（习惯前缀 trt），操作本身无参数：

```xml
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Body>
    <!-- 鉴权头按第四章补 UsernameToken，此处省略 -->
    <trt:GetProfiles xmlns:trt="http://www.onvif.org/ver10/media/wsdl"/>
  </s:Body>
</s:Envelope>
```

响应是所有 profile 的完整配置树。第一眼要适应一个历史怪癖：**响应元素与子元素都叫 `Profiles`（复数）**，设备有几个 profile 就重复几份。剥开第一个 profile 的壳与视频源配置：

```xml
<trt:GetProfilesResponse xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
                         xmlns:tt="http://www.onvif.org/ver10/schema">
  <trt:Profiles token="profile_1">              <!-- profile 自己的 token -->
    <tt:Name>mainstream</tt:Name>
    <!-- 第一件：视频源配置——从哪个传感器、取哪块画面 -->
    <tt:VideoSourceConfiguration token="vsc_1">
      <tt:Name>video_source_main</tt:Name>
      <tt:UseCount>2</tt:UseCount>              <!-- 被 2 个 profile 共享引用 -->
      <tt:SourceToken>vs_1</tt:SourceToken>     <!-- 指向物理传感器实体 -->
      <tt:Bounds x="0" y="0" width="1920" height="1080"/>
    </tt:VideoSourceConfiguration>
    <!-- 第二件：视频编码配置，5.3 逐字段拆 -->
    <tt:VideoEncoderConfiguration token="vec_1">…</tt:VideoEncoderConfiguration>
  </trt:Profiles>
  <trt:Profiles token="profile_2">…</trt:Profiles>   <!-- 第二个 profile -->
</trt:GetProfilesResponse>
```

读这份响应的三个看点：

- **UseCount 暴露共享关系**：`vsc_1` 的 UseCount=2 说明它被两个 profile 引用——这是判断"改这个配置会波及谁"的唯一线索，动手改之前必看；
- **GetProfiles 全量返回**，Media1 的它没有过滤参数；取单个用 GetProfile（单数，传 token）；
- **多 profile 与行业黑话的对应**：安防语境的"主码流/子码流"在 ONVIF 里就是两个独立 profile——主码流是高分辨率高码率那份（录像用），子码流是低分辨率那份（多路预览/移动端用）。NVR 添加一台摄像机时让你勾"主/子码流"，勾的就是 profile token。

## 5.3 VideoEncoderConfiguration：分辨率、帧率与 GOP 的旋钮

第二件套拆开，是媒体配置里信息密度最高的一个对象：

```xml
<tt:VideoEncoderConfiguration token="vec_1">
  <tt:Name>h264_1080p_25</tt:Name>
  <tt:UseCount>1</tt:UseCount>
  <tt:Encoding>H264</tt:Encoding>
  <tt:Resolution>
    <tt:Width>1920</tt:Width>
    <tt:Height>1080</tt:Height>
  </tt:Resolution>
  <tt:Quality>5</tt:Quality>
  <tt:RateControl>
    <tt:FrameRateLimit>25</tt:FrameRateLimit>   <!-- 帧率上限（fps） -->
    <tt:EncodingInterval>1</tt:EncodingInterval> <!-- 抽帧间隔 -->
    <tt:BitrateLimit>4096</tt:BitrateLimit>     <!-- 码率上限（kbps） -->
  </tt:RateControl>
  <tt:H264>
    <tt:GovLength>50</tt:GovLength>             <!-- 两个 I 帧间的帧数 -->
    <tt:H264Profile>Main</tt:H264Profile>
  </tt:H264>
  <tt:Multicast>
    <tt:Address><tt:Type>IPv4</tt:Type><tt:IPv4Address>0.0.0.0</tt:IPv4Address></tt:Address>
    <tt:Port>0</tt:Port><tt:TTL>1</tt:TTL><tt:AutoStart>false</tt:AutoStart>
  </tt:Multicast>
  <tt:SessionTimeout>PT60S</tt:SessionTimeout>
</tt:VideoEncoderConfiguration>
```

| 字段             | 含义                             | 调参时的联动                                 |
| ---------------- | -------------------------------- | -------------------------------------------- |
| Encoding         | 编码格式（JPEG/MPEG4/H264）      | H.265 的身份问题见下文                       |
| Resolution       | 输出分辨率                       | 须落在传感器能力内，且常与帧率档位绑定       |
| Quality          | 质量档位（刻度由设备定义）       | MJPEG 流的主旋钮                             |
| FrameRateLimit   | 帧率上限（fps）                  | 分辨率×帧率才是吞吐，单看一个没意义          |
| EncodingInterval | 抽帧间隔：每 N 帧编 1 帧         | 实际帧率 = FrameRateLimit / EncodingInterval |
| BitrateLimit     | 码率上限（kbps），4096 即 4 Mbps | 1080p/H.264 常见数 Mbps 量级                 |
| GovLength        | 两个 I 帧之间的帧数（GOP 长度）  | 25fps + GovLength 50 = 每 2 秒一个随机进入点 |
| H264Profile      | Baseline/Main/High               | 压缩率与解码算力的三档取舍                   |
| SessionTimeout   | 会话超时（ISO 8601 时长，PT60S） | 与 RTSP 保活联动（ch06 展开）                |

**GovLength 是最容易被轻视的旋钮**。I 帧最贵（完整帧内编码），GOP 拉长省码率；但拉流起播要等第一个 I 帧、丢一个 I 帧后花屏要持续到下一个 I 帧才能自愈——GOP 越长，首帧延迟与容错窗越差。监控场景常见 2–4 秒 GOP 的量级，就是这个折中的落点；把延迟敏感与带宽敏感两类流配成不同 GovLength，正是双 profile 存在的理由之一。

**H.264 与 H.265 的取舍**：同画质下 H.265 大致能省三到五成码率（量级估计），代价是编解码算力与生态兼容——老 NVR、浏览器软解、低端移动端都可能掉队。规范侧还有个尴尬：Media1 的 `tt:VideoEncoding` 枚举只定义了 JPEG/MPEG4/H264 三值，H.265 是 Profile T 时代才转正的，正式户口在 Media2 schema（5.6）；不少设备在 Media1 响应里直接写 `H265` 字面量，严格做枚举校验的客户端会在这里翻车（ch09 的互通坑名单预告）。若选 H.264，Profile 档位的直觉是：Baseline 砍特性换鲁棒与低算力（低延迟、老旧解码端），Main 平衡，High 压缩率最好但解码最贵。

最后一个纪律：**别猜参数，先问设备**。GetVideoEncoderConfigurationOptions（传配置 token 或 profile token）返回该配置的合法取值——可用分辨率列表（ResolutionsAvailable）、帧率/抽帧/码率的区间、GovLength 区间、支持的 H264Profile 列表。Set 越界理论上换回 ch03 讲过的 SOAP fault；但各设备校验松紧不一，"Set 成功、参数被悄悄收敛"的宽松实现也存在，所以核对永远不可省。

## 5.4 读改写：先 Get 再 Set 的纪律

改编码参数的标准循环是四步，一步不能省：

```text
GetVideoEncoderConfiguration（拿到完整配置对象）
   → GetVideoEncoderConfigurationOptions（核对该 token 的合法取值）
   → 内存中只改目标字段
   → SetVideoEncoderConfiguration 传回完整对象
```

三条语义红线，每条都对应一类真实事故：

- **Set 是全量覆盖，不是增量 patch**。报文必须传回整个 Configuration 元素（含所有你不想改的字段），漏传等于把字段置默认。"先 Get 再 Set"因此不是习惯而是纪律——手搓一个只含目标字段的 Set 就是事故现场；
- **没有乐观锁**。配置对象没有版本号/ETag/CAS 之类字段，两个客户端并发 Get→改→Set 就是后写覆盖先写，规范层面无解，工程上只能靠"管理面单写者"之类的约定；
- **改动波及全部引用者**。目标配置若被多个 profile 共享（UseCount>1），一次 Set 就是几个码流一起变。想只动子码流，先在 5.2 的响应里把引用关系看清楚，确认手里是子码流独占的配置 token。

```xml
<trt:SetVideoEncoderConfiguration xmlns:trt="http://www.onvif.org/ver10/media/wsdl">
  <trt:Configuration forcePersist="true" token="vec_1">
    <!-- tt:Name / Resolution / Quality / RateControl / H264 / Multicast /
         SessionTimeout 全部原样传回，仅改其中一处 -->
  </trt:Configuration>
</trt:SetVideoEncoderConfiguration>
```

`forcePersist` 是 Configuration 元素上的布尔属性，管的是"配置正被活跃流使用时怎么办"：置 true 要求设备立即修改并持久化，置 false 时设备可以推迟到流停止、也可能直接拒绝。各固件对它的解读与执行力度不一，工程上更稳的惯例是**改编码参数前先停流**，改完再重新拉流，顺带验证新参数生效：

```bash
# ffprobe 核对 RTSP 流的实际编码参数（URI 以 GetStreamUri 返回为准，见 ch06）
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,r_frame_rate \
  rtsp://192.168.1.64:554/profile1
```

## 5.5 动态组装：CreateProfile 与 AddConfiguration

Media1 的前半生里 profile 基本是出厂预置、客户端只能挑不能造；动态拼装操作是 ONVIF 2.2 前后（大致 2010 年代初）才补上的：

| 操作                | 参数要点                                      | 语义                                                     |
| ------------------- | --------------------------------------------- | -------------------------------------------------------- |
| CreateProfile       | Name（可建议 Token）                          | 造一个空 profile，响应返回设备分配的 token               |
| AddConfiguration    | ProfileToken + 各类配置 token（多类可一次挂） | 把已有配置实体挂进 profile                               |
| RemoveConfiguration | ProfileToken + 配置类型列表（含 All）         | 摘掉指定类别的配置                                       |
| DeleteProfile       | ProfileToken                                  | 删 profile；被它独占引用的底层配置是否级联清理由设备自定 |

给双 profile 设备拼第三路缩略图流，两步走：

```xml
<!-- ① 造空壳；响应返回 <trt:Profile token="profile_3"/> -->
<trt:CreateProfile>
  <trt:Name>thumbnail</trt:Name>
</trt:CreateProfile>

<!-- ② 挂件：复用主源配置 + 挂上设备预置的 JPEG 编码配置 -->
<trt:AddConfiguration>
  <trt:ProfileToken>profile_3</trt:ProfileToken>
  <trt:VideoSourceConfiguration>vsc_1</trt:VideoSourceConfiguration>
  <trt:VideoEncoderConfiguration>vec_jpeg</trt:VideoEncoderConfiguration>
</trt:AddConfiguration>
```

注意这套能力的**上限**：AddConfiguration 挂的是**已有**配置实体，而 Media1 没有"凭空创建一个新编码器配置"的操作（Set 只能改已有的）。想要第三路流，前提是设备出厂就预置了可挂的第三个编码器配置；想要第五路而设备只预置了四个，那就没了。这个缺口正是 Media2 要补的。顺带一提：早期规范里还有 AddVideoEncoderConfiguration 这类一次挂一件的老操作，AddConfiguration 是后来补的批量版，读老设备的 WSDL 看到两套并存不必困惑。

## 5.6 Media2（tr2）：合并、扁平化与双栈并存

第一代媒体服务随规范膨胀暴露了两个结构问题：**服务越拆越碎**——录像、回放、搜索、接收各自独立成服务，客户端做一件事要在多个服务端点间跳；**配置模型半残**——配置实体只能改不能造，profile 组装要 Create→Add 两步接力。第二 Media2（命名空间 `http://www.onvif.org/ver20/media/wsdl`，习惯前缀 **tr2**；随 Profile T 一代登场——Media2 Service Spec 首发于规范 16.12（2016 年末），Profile T 于 2019 年落地，属 2010 年代后期）动了一次大手术，三个方向：

1. **服务合并**：媒体、录像、回放、搜索、接收归并进同一 WSDL，统一入口，操作名沿用 GetProfiles/GetStreamUri 等老名字；
2. **配置模型扁平化**：各类配置实体归一到统一基类（token/name/useCount 一套语义），每类配置配齐 Create/Get\*/Set/Delete/GetOptions 全家桶——"只能改不能造"的缺口补上了；
3. **组装一步到位**：CreateProfile 直接携带 ConfigurationSet，创建即挂件，不再需要两步接力。

| 维度         | Media1（trt，ver10）                | Media2（tr2，ver20）                     |
| ------------ | ----------------------------------- | ---------------------------------------- |
| 服务边界     | media 独立成服务                    | 媒体/录像/回放/搜索/接收合并             |
| 创建配置实体 | 无（Set 只能改已有）                | CreateVideoEncoderConfiguration 等全家族 |
| 组装 profile | CreateProfile→AddConfiguration 两步 | CreateProfile 带 ConfigurationSet 一步   |
| H.265        | 枚举外字面量（厂商私塞）            | schema 正式成员                          |
| GetProfiles  | 无参全量返回                        | 可传 token 列表按需取                    |

新旧两代并存的现实格局：

- **怎么探测**：[[ch03-soap-services|第三章]]的 GetServices 响应里，ver10 与 ver20 的 media 命名空间各是一条目，看设备报了哪个或都报；
- **怎么共存**：服务由 SOAP Body 的命名空间区分而非 URL——同一台设备的同一个端点，Body 里写 `trt:GetProfiles` 走一代、写 `tr2:GetProfiles` 走二代（ch03"端点是场所、命名空间才是语义"在这里回收）；
- **客户端策略**：只支持 Media1 的存量设备至今大量在役，新设备普遍双栈。常规打法是先问 Media2、没有再退 Media1；两代各自的 profile/配置 token 互不相通，别混用。

辨析一句避免混淆：Media2 是**服务规范**，Profile T 是**能力声明**——Profile T 以 Media2 为载体表达 H.265、双向音频等能力（Profile 语义见 [[ch01-onvif-overview|第一章]]），但"实现了 Media2"不等于"通过认证 Profile T"。

## 5.7 小结

- MediaProfile 是**引用的聚合体**而非值的容器：源配置 + 编码配置 + 可选挂件；ReferenceToken 是全链路索引键，配置实体独立存活、可被多 profile 共享（UseCount 即引用计数）。
- 编码参数的核心旋钮：Resolution、FrameRateLimit/EncodingInterval（抽帧）、GovLength（GOP：省码率 vs 首帧延迟与容错窗）、BitrateLimit；H.265 省大致三到五成码率但户口在 Media2——改前先 GetVideoEncoderConfigurationOptions，别猜。
- 读改写纪律：Set 全量覆盖、无乐观锁、波及全部引用者；forcePersist 管活跃流场景，停流再改最稳，改完用 ffprobe 对账。
- 动态组装 CreateProfile/AddConfiguration/DeleteProfile 只能重组已有配置实体——Media1 造不出新编码器配置，路数上限出厂即定。
- Media2 合并服务族、扁平化配置模型、组装一步到位；两代以命名空间区分、在同一端点双栈并存，客户端先探 tr2 再退 trt。

三件套配好了，手里攥着 profile token——下一章就把它换成画面：GetStreamUri 的参数与流类型（RTP 单播/组播）、RTSP 的 DESCRIBE/SETUP/PLAY 三段式信令、RTP 如何打包 H.264 帧，以及怎么用 ffprobe 与抓包把控制面承诺的编码参数与媒体面的实际逐项对账——从"会配了"到"看到画面"。[[ch06-rtsp-streaming|第六章：取流全链]]。
