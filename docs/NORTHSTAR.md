# 优先级栈与持续开发循环

> 2026-07-24 起。这份文件是**我自己从代码和产品第一性原理得出的判断**，不是对 `PRODUCT_VISION.md` / `PRODUCT_ROADMAP.md` / `design/*.html` 的转述——那些是早期 AI 会话写的，用户已明确表示不受其约束。它们可以当作"已经建了什么"的背景，不当作需求。

## 0. 商业前提

yt-dlp 是免费公开的，谁都能 `pip install`。所以一个要收钱的 GUI 下载器只可能卖三样东西：

1. **免费方案不行的时候它行** —— 可靠性、登录态、站点变更后的恢复
2. **省掉思考** —— 不用终端、不用记 format code
3. **做 yt-dlp 做不到的事** —— 只有这一条是长期护城河

第 1、2 条决定用户会不会留下，第 3 条决定他们会不会跟别人讲。**当前代码在 1、2 上投入很重，在 3 上几乎为零。**

## 1. 硬约束

- **测试源不用国外 CDN**。国外源的失败无法区分"我们的 bug"和"网络"。真实下载测试用国内可达源。
- 不向用户暴露 yt-dlp / ffmpeg / deno / 命令行术语。
- AI 能力优先本地推理。任何联网推理必须是用户显式开启，且说明数据去向。
- AI 只**建议**，不静默改写用户文件。
- 视觉改动不自动合并（测试验不了），附 QA 截图等人看。

## 2. 优先级栈

### A · 信任地基：先让它不出错

| # | 事项 | 状态 |
|---|---|---|
| A1 | **引擎无视任务的 HTTP method 和 body，永远发 GET** —— 表单/POST 触发的下载静默写入错误内容（登录页、错误文档）而不报错 | ✅ 2026-07-24 修复（`1a37291`）。附带发现 `postData` 一字段两用（同时存 yt-dlp 选项 JSON），已用 method 白名单锁住 |
| A2 | **默认测试套件里有真连 YouTube 的测试**随机 403 限流，破坏"全绿才自动合并"的门禁 | ✅ 2026-07-24 修复。`LiveNetworkGate` 把 4 个 live 测试改为 `NDM_LIVE_NETWORK_TESTS=1` 显式开启；同文件 8 个纯逻辑测试仍在默认套件里 |
| A3 | **长时稳定性** | 🟡 2026-07-24 仪器建好：`swift run NDMSoak`（本地 origin，不打外网）。**150s 基线干净**：472 轮、1888 个任务走完创建/暂停/续传/交付/删除，fd 恒定 14，任务行回 0，收敛后 746 KB/min。**但 8 小时本身尚未验证** —— 需要你手动跑 `swift run NDMSoak --duration 28800`。短跑必然显示增长（60s 那次收敛后仍 38.9 MB/min，因为还在 warm-up），真信号只能来自长跑。休眠唤醒也还没覆盖 |
| A7 | **`remove` 失败时销毁续传数据** | ✅ 2026-07-24 修复。不可逆的 support 目录删除移出 `defer`，只在 `store.delete` 成功后执行；引擎注册表清理留在 `defer`（引擎已无条件取消，留着更糟）。线上可达路径是 `AppFileRecycler` 走废纸篓失败（权限/锁定/iCloud） |
| A8 | **`remove` 失败后 status 滞留** | ✅ 2026-07-24 查清：**上一轮我把前提推错了**。活跃下载这条路本来就正确——`remove` 在做破坏性操作前会 `await runningTask.value`，`runEngine` 的 cancel 分支已写 `.incomplete`。崩溃遗留的 `.downloading` 也本来就被 `DownloadStore.recoverInterruptedTasks()` 在启动时清掉（`AppDelegate.swift:67`）。仍加了 6 行不变量守卫，让"取消后没有东西自称在下载"成为 `remove` 的本地后置条件，而不是依赖一条很远的启动 SQL；两条路径都写了测试。**这是补理论缺口，不是修线上 bug** |
| A4 | **HLS / MKV 边缘行为** | ✅ 2026-07-24。修了**密钥轮换**、**中途 `METHOD=NONE`**、**交付文件名丢失真实容器**三个静默产出坏文件的 bug。验证本来就正确的：IV 缺省用 media sequence、密钥取不到会失败、分片 404 会中止、`#EXT-X-DISCONTINUITY` 不需要处理（不同时间戳基准拼接后仍交付完整可播 MP4，已写测试钉住） |
| A9 | **分轨音频没有音频流时静默交付无声视频** | 🟡 2026-07-24 引擎侧完成：不硬失败（用户宁愿要无声视频也不要什么都没有），但混流后探测输出真实音频流，缺失则把 `DeliveryNote.audioTrackMissing` 落到 `DownloadTask.deliveryNote`（新增列 + 迁移）。**界面尚未呈现**——见 A11 |
| A11 | **完成页 / 详情页呈现 `deliveryNote`** | ⬜ 数据已持久化且有人话文案（`DeliveryNote.title` / `.detail`，测试禁止出现 ffmpeg/codec 等术语）。这是纯视觉改动，按协议需停下等审阅，所以留给你决定放在哪、怎么呈现 |
| A5 | **NDM Relay 实机 smoke** —— 扩展是最大入口漏斗，却是唯一没在真机验过的环节 | ⬜ |
| A6 | **一条命令跑完三道门禁** | ✅ 2026-07-24 `Scripts/check.sh`。汇总真实总数（数测试用例，不读会骗人的 "Executed N tests" 末行），任一失败非零退出，末尾提示三条触网命令。三条退出路径都验证过。仓库仍无 CI，但门禁现在对人和对循环是同一条命令 |

### B · 可测量：不测就不能改进

| # | 事项 | 状态 |
|---|---|---|
| B1 | **真实成功率 harness** | ✅ 2026-07-24。`swift run NDMProbe`；用例在 `Scripts/success-rate-cases.json`。走 App 真实路径（直链 `addURL`+`startAndWait`，媒体页 `MediaPreflightStore`+`startYtDlp`），按 SHA-256 校验交付内容。首次基线 **3/3 · 中位 0.43s** |

`PRODUCT_VISION.md` 把"投递到可用文件的成功率与中位耗时"定为北极星，这个判断是对的，但**至今没有任何东西在测它**。307 个单元测试测的是逻辑正确性，不是真实世界能不能下下来。对一个下载器，"能不能下下来"就是产品本身。

### C · 护城河：从下载器变成素材库

核心判断：**用户下载视频的真实目的，往往是要里面的信息，不是要那个文件。** 所有下载器都停在文件。停在"可读、可搜、可跳转"的那个，不在跟 Downie 竞争。

而且 2026 年这件事的成本已经塌了：Apple silicon 上本地语音识别又快又免费，本地跑还是云服务无法用价格抵消的隐私优势。

| # | 事项 | 现状 |
|---|---|---|
| C1 | **转写内置化** | 🟡 2026-07-24 选型与拆解已定，见下方专节。现在 `ScribeStudioIntegration.swift` 只是 `NSWorkspace.open` 把文件丢给独立 Electron App（`dev.yuan.scribestudio`，在 `~/Documents/tinggao`），用户要装第二个 App → 这条能力事实上等于没有 |
| C2 | **收件箱内容全文搜索** | 侧栏现在只按状态/类型/文件名搜。要能搜内容并定位到那一秒。沉淀越多越离不开 = 留存 |
| C3 | **章节 + 摘要** | 成本最低感知最强；顺带解决"整个产品没有任何可截图传播的画面"这个增长问题 |
| C4 | **订阅追更** | 关注 UP 主/频道自动下。把工具变成服务，也是订阅制收费唯一站得住的锚点 |
| C5 | **Raycast / Shortcuts / CLI** | 对 Mac 极客口碑效率极高、成本极低；Raycast 商店是免费传播渠道 |
| C6 | **投送到手机 / NAS** | 下完直接进相册或 NAS。国内高频真实需求 |

## C1 转写内置化：选型与拆解

> 2026-07-24 定。下面的数字全部是在本机实测得到的，不是查资料或凭印象。

### 1. 引擎选型：macOS 26+ 的 `SpeechAnalyzer`，明确不用 whisper.cpp

实测（macOS 27.0，Apple silicon）：

| 事实 | 实测值 |
|---|---|
| `SpeechAnalyzer` / `SpeechTranscriber` / `AssetInventory` 可用版本 | `@available(anyAppleOS 26, *)` —— **macOS 26+** |
| 支持语言数 | 45 |
| 中文 | `zh_CN` · `zh_TW` · `zh_HK` 三个都支持；`zh-CN` 正确映射到 `zh_CN` |
| 原装机器已安装语言 | 11 个，**含 `zh_CN`** —— 中国用户主语言很可能零下载 |
| 中文端到端质量 | `这是一段中文测试语音用来验证本地转写是否可用。`（仅丢逗号） |
| 速度 | 5.36s 音频耗时 0.33s ≈ **16 倍实时** |
| 英文端到端 | `This is an English test of undevised transcription.`（"on device" 听成 "undevised"，TTS 合成音 + 难词） |

**结论：用 Apple 的。** whisper.cpp 明确不做，理由是真实成本对比而非偏好：

- 模型体积：base ≈142MB、small ≈466MB，而中文要到 small 以上才有可比质量；发行包已经背着 yt-dlp + ffmpeg + deno
- 我们得自建一条签名模型分发通道（等于再做一个 `SiteCompatibilityUpdater`），是真工作量也是真风险
- Apple 的模型免费、已装、由系统签名，中文实测质量足够好

**代价必须写清楚**：`Package.swift` 最低是 macOS 13，所以转写**只能按功能门控**在 macOS 26+。低版本用户看不到这个功能，而不是看到一个坏的版本。不为了它抬高整个 App 的最低系统版本。

### 2. 模型分发

不需要我们分发。`AssetInventory.status(forModules:)` 报告就绪状态，`assetInstallationRequest(supporting:)` 让**系统**下载并管理，走 Apple 的签名与信任链。这比 `SiteCompatibilityUpdater` 那套自建 Ed25519 通道更强，因为我们根本不碰二进制。

首次使用需要下载语言包时，必须呈现为一个明确阶段（"正在准备中文语音模型"），不能表现为卡住。

### 3. 进度

`prepareToAnalyze(in:withProgressReadyHandler:)` 会给出真实的 `Foundation.Progress`。所以**不需要伪造百分比**。转写并入现有 `DownloadProgress.phase` 的单调旅程，作为交付的最后一段，绝不新开第二条进度条与主进度打架。

### 4. 字幕落盘

用 `.timeIndexedTranscriptionWithAlternatives` preset 拿带时间轴的结果 → 写 SRT，作为附属文件进入 `SmartFinalize` 的 CompletionStack，**不散成独立任务**。

**命名要注意（2026-07-24 更正）**：我最初写"必须带语言后缀 `片名.zh-Hans.srt`"，但没查既有实现。`YtDlpTool.normalizeSubtitleSidecar` 现在**故意**统一成 `片名.srt`（不带语言），理由是让播放器无需语言规则就能发现字幕。C1-1 的 `Plan.languageTag` 只作为信息提供，实际命名沿用既有约定；要不要改成带后缀由 C1-5 明确决定，不许悄悄分叉出两套命名。

### 5. 隐私

`SpeechAnalyzer` 完全本机推理，不上传。这是默认也是唯一路径。将来若有云端选项，必须显式开启并说明数据去向——但 v1 不做云端。

### 6. 与 ScribeStudio 的关系：保留，但降级为"编辑棚"

内置之后，NDM 自己交付文稿与字幕，不再依赖外部 App。但 ScribeStudio 能做的更多（说话人分离、口水词清理、逐段编辑、多格式导出），所以那条接力入口**保留**为"在 ScribeStudio 中编辑"，仅当用户已安装时出现。产品叙事：**NDM 给你可读可搜的文稿，ScribeStudio 是要精修时才进的棚。**

### 7. 拆解（每步独立可交付、每步过门禁）

| 步 | 内容 | 备注 |
|---|---|---|
| C1-1 | 纯逻辑：转写资格与计划 | ✅ 2026-07-24 `TranscriptionWorkflow.decide` + `Environment`/`Plan`/`Decision`/`UnavailableReason`，30 个测试 |
| C1-2 | 纯逻辑：带时间轴结果 → SRT 序列化（时间戳格式、CJK 断行、过短/过长 cue 合并） | 纯函数，极易测 |
| C1-3 | `SpeechTranscriptionEngine`（NDMEngine，`@available(macOS 26, *)`）：音频转换管线 + 结果收集。探针已验证可行 | 集成测试用 `say` 生成音频，本地无网络，低版本 skip |
| C1-4 | 语言包就绪：`AssetInventory` 状态与安装请求呈现为明确阶段 | |
| C1-5 | 接入交付：字幕落盘命名 + 进入 CompletionStack + 进度并入单调旅程 | |
| C1-6 | 设置开关（默认行为待定）+ ScribeStudio 入口降级为"编辑" | 含视觉改动，需停下等审阅 |

### 明确不做

- AI 聊天助手界面（下载器不需要对话框）
- AI 猜链接 / 绕过站点权限（不可靠）
- AI 解释下载错误（`DownloadDiagnostic` 的规则文案更准更快，联网推理是净损失）
- AI 预测速度（无意义）
- 命名、图标、支付、官网、公证、Sparkle —— 用户明确要求本阶段全部后置

## 3. 循环协议

1. 读本文件，取最靠前的未完成项。一轮做一件，做完整。
2. 三道门禁：**`Scripts/check.sh`**（`swift build` · `swift test` · Relay node 测试；
   任一失败非零退出）。触网的东西一律不在门禁里，需要时显式跑：
   - `NDM_LIVE_NETWORK_TESTS=1 swift test --filter YtDlpToolIntegrationTests`
   - `swift run NDMProbe` —— 交付成功率与中位耗时
   - `swift run NDMSoak --duration 28800` —— 真正的 8 小时长跑
3. 全绿且不涉及品牌/定价/购买 URL/许可证密钥/用户数据路径迁移 → 直接提交到当前工作分支。否则留分支等审阅。
4. 纯视觉改动一律停下等审阅。
5. 在下面追加日志。报告诚实：失败贴真实输出，跳过就说跳过。
6. 额度用尽后，新加坡时间 8:01am（美西 17:01）的恢复锚点会把循环接起来。

## 4. 日志

| 日期 | 事项 | 结论 |
|---|---|---|
| 2026-07-24 | 基线体检 | `swift build` 绿；三个测试目标全绿。把上一会话 16 个未提交文件收成 `d94ad1c` 拿到干净基线 |
| 2026-07-24 | A1 引擎 POST 修复 | 提交 `1a37291`。3 个新测试；`LocalRangeServer` 增加方法/body 捕获并按 Content-Length 读完整请求（原来单次 receive 只拿到头，body 断言会假通过）。全套回归绿；期间遇到的一次 YouTube 403 已验证为限流抖动、非回归 → 立项 A2 |
| 2026-07-24 | A2 触网测试门 | `LiveNetworkGate` + 3 个自测；4 个 live 测试改为显式开启，两个方向都验证过（默认跳过、`=1` 真的会跑）。确认没有发行脚本依赖 `swift test`，所以发行门禁未被削弱。顺带发现仓库无 CI → 立项 A6 |
| 2026-07-24 | C1-1 资格与计划层 | `TranscriptionWorkflow` 从 15 行扩到完整决策层：`Environment`（可用性/支持语言/已装语言/首选语言全部注入，纯层不 import Speech，所以测试在任何系统版本都能跑）、`Plan`（含 `source` 记录**为什么**选这个语言，猜错了可追溯）、`Decision`、`UnavailableReason`（人话文案 + 测试禁术语）。语言优先级：站点 > 标题文字系统 > 系统首选 > 英文兜底；站点故意压过系统首选（B站视频是中文语音，与界面语言无关），但全球平台（YouTube/TikTok/Vimeo）**不按域名猜**。假名优先于汉字，否则日语视频会被当成中文。30 个测试。两处自我更正：① 上一轮写的"字幕必须带语言后缀"与既有 `normalizeSubtitleSidecar`（故意不带语言）冲突，已改为留给 C1-5 明确决定；② 实测本机 `Locale.preferredLanguages` 是 `["zh-Hans-US", "en-US"]`——带非中文区域，我原来的实现只靠 base 语言回退**碰巧**命中 zh_CN，改为按脚本子标签判断，否则支持列表顺序一变简体用户就会被分到繁体模型 |
| 2026-07-24 | C1 选型与拆解（未写实现） | 本轮只做决策，不写实现代码。所有选型依据都是本机实测：写探针查到 `SpeechAnalyzer`/`SpeechTranscriber`/`AssetInventory` 是 `@available(anyAppleOS 26, *)`、45 语言、中文三档全支持、`zh_CN` 在原装机器上**已安装**；再用 `say` 生成真语音做端到端转写，中文近乎完美、约 16 倍实时。据此判定 **whisper.cpp 明确不做**（模型体积 + 需自建签名分发 vs Apple 免费已装已签名），并接受"转写只在 macOS 26+ 按功能门控"这个代价，不抬高整个 App 最低版本。拆成 C1-1…C1-6，第一步是纯逻辑的资格与计划层 |
| 2026-07-24 | A9 无声交付要说出来 | 新增 `DeliveryNote`（成功但不是用户想要的交付事实，与描述失败的 `DownloadDiagnostic` 分开）+ `DownloadTask.deliveryNote` 列与迁移 + `DownloadProgress.deliveryNote` + `runEngine` 落库。HLS 混流后探测输出真实音频流；探测复用了仓库里**已有的** `FFmpegTool.streamPresence`（我先写了个重复的解析器，发现后删掉了）。探测失败返回 nil 而非 false，避免把"测不出来"当成"确认无声"。测试：存储往返、未知键、清除、迁移幂等、文案禁术语；原本钉住"静默无声"的测试改为断言必须落备注；音频只是偏短则明确断言**不**落备注。364 passed。`NDMProbe` 首跑 B站 失败（`下载失败`）——先核对手改的 SQL 占位符（23/23 正确），再单跑与全跑各一次均 3/3 通过，判定为该视频本会话被下载多次后的限流抖动，非回归 |
| 2026-07-24 | A8 status 滞留（前提被推翻） | 两个测试分别验活跃与陈旧两条路：活跃路**本来就对**（先 await 运行任务，cancel 分支已写 `.incomplete`）；陈旧 `.downloading` 在隔离测试里能复现，但线上不可达——`recoverInterruptedTasks()` 启动时一条 UPDATE 就把所有 `downloading` 清成 `incomplete`。我上一轮凭 grep 没命中它就断言"没有启动修复"，是错的。保留 6 行守卫（让后置条件本地可验，不依赖远处的启动 SQL）并如实标注为补理论缺口。357 passed |
| 2026-07-24 | A4 收尾：DISCONTINUITY 与容器名 | `#EXT-X-DISCONTINUITY` **本来就不需要处理**——用两段不同时间戳基准的真实 TS 验证，拼接后交付完整可播 MP4（用 AVFoundation 而非 ffprobe 验，因为"Mac 上能不能播"才是产品承诺）。没有为了有产出而加代码，改为写测试钉住。但顺手挖到一个更严重的：**master playlist 交付的文件叫 `download.m3u8`**，字节是真 MP4 但双击打不开。两层原因：① `DownloadFilename.extensionFromURL` 会把 `.m3u8`/`.mpd` 当成媒体扩展名拼上去；② `runEngine` 的"恢复名字"逻辑因为词干 `download` 在无用词表里而触发，把引擎 remux 好的 `.mp4` 改成 URL 派生的扩展名——本意是救无扩展名的 CDN token，实际把真实容器信息毁了。两处都修：播放列表后缀永不作为交付扩展名；恢复只换词干、绝不降级或丢弃磁盘上的真实扩展名。另立 A9（分轨音频无音频流时静默交付无声视频）。355 passed；`NDMProbe` 复跑 3/3 确认真实交付未回归 |
| 2026-07-24 | A4 HLS AES-128 密钥轮换 | 先写 4 个测试探边界：IV 缺省用 media sequence ✅ 本来就对、密钥 404 会失败 ✅ 本来就对、**密钥轮换 ❌（48 字节 vs 应有 32）**、**中途 `METHOD=NONE` ❌（42 vs 26）**。根因：解析器把 `#EXT-X-KEY` 无条件覆盖到 `media.key`，只有最后一个存活，引擎取一把密钥解全部分片 → 全程不报错的乱码，与 A1 同族。修法：密钥按分片关联（`Segment.key`），`Media.key` 改为从 segments 计算以消除两份真相，引擎按 URI 缓存密钥、逐分片解密，`absolutize` 逐分片解析密钥 URI。+7 测试（352 passed）。顺手确认 `#EXT-X-DISCONTINUITY` 在全仓库零处理 |
| 2026-07-24 | A6 统一门禁脚本 | `Scripts/check.sh`。发现原本打算复用的 "Executed N tests" 末行其实只是最后一个 target 的数字（显示 6，真实 345）——改成数测试用例。三条退出路径都真实验证过：植入临时失败测试（exit 1，报 345 passed/1 failed）、用 `NDM_RELAY_TESTS_DIR` 指向含失败用例的临时目录（exit 1）、目录不存在（exit 1）、全绿（exit 0）。README 验证段改为指向它 |
| 2026-07-24 | A7 失败删除销毁续传数据 | 先写测试复现（植入真实 `segments.bin` + `seg.x0`，注入会抛错的 recycler）——确认两者都被删掉；修复后 7 个删除测试全过，包括原有那个断言"成功时必须删掉 support 目录"的测试。顺手扫了 `DownloadManager` 其余 `defer`，没有同类问题。分出 A8（status 可能滞留） |
| 2026-07-24 | A3 长跑压测仪器 | `SoakAnalysis`（纯逻辑，19 个离线测试）+ `NDMSoak` 可执行，自带本地 origin。**150s 基线：472 轮 · fd 14→14 · 行 0→0 · 收敛后 746 KB/min · 无 finding**。三个过程发现：① 首跑显示"1452 行一个没删"——查明是我没注入 recycler 导致 `remove(deleteFile:true)` 抛 `fileRecyclingUnavailable`，而我用 `try?` 吞了错误；顺此发现真问题 A7（defer 在抛异常时仍拆除 support 目录，留下行在但分段已删的任务）；② 单条直线拟合会把正在收敛的曲线报成 8.3 MB/min 的可怕速率——改为用收敛后窗口下判断，同时两个数都显示；③ 失败路径用 `--max-growth-fraction 0.0001` 验证过真的会 exit 3。**注意：8 小时本身没验证，只证明了仪器有效** |
| 2026-07-24 | B1 成功率 harness | 新增 `NDMDiagnostics` 库（纯逻辑，25 个离线测试进默认套件）+ `NDMProbe` 可执行（触网，永不进 `swift test`）。**首次真实基线 3/3 · 中位 0.43s**（直链 2/2 中位 0.39s，B站页面 1/1 3.71s / 9.2MB）。三个过程中的真实发现：① 清华镜像限流会返回 HTML 拦截页且 Content-Length 诚实——SHA-256 校验抓住了它，否则会被记成"成功交付"，据此换用阿里云源并新增 `interstitialHint` 直接指出"服务器给的是页面不是文件"；② `MediaPreflightStore` 只有共享实例，重复轮会命中探测缓存污染计时，加了 `uncached()`；③ 各轮不独立，首轮替后面付 yt-dlp 冷启动（21.8s vs 3.8s），加了 `--warmup` 丢弃轮，验证后两轮回到 3.54s/3.79s |
