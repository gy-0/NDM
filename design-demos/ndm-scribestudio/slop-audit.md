# NDM × ScribeStudio · Kill AI Slop Triage

> 审计日期：2026-07-21
> 状态：用户已授权应用全部确认组；第一轮真实源码清理与聚焦窗口验收已完成

## 第一轮应用结果

- ScribeStudio：活动 renderer 的自动扫描从 7 个命中降为 0；删除重复英文 kicker，改用实色画布/按钮/舞台，标签不再使用 10px，左侧设置与下方工具区改为连续 pane。另修复 1120px Mac 窗口下文稿区覆盖生成文件/日志的响应式网格回归。
- NDM：详情、进度、Pro 与设置中的目标微型字号已上调；Pro/媒体权限提示不再使用淡色圆角 icon well；Inspector、设置、Pro 权益区的内层容器已改成透明连续信息面。
- BetterNDM：站点原生圆形按钮继续保留，没有因扫描命中而误改。
- 聚焦截图：`verified/kill-ai-slop-scribestudio-focused.jpg`、`verified/kill-ai-slop-ndm-main-focused.jpg`、`verified/kill-ai-slop-ndm-settings-focused.jpg`、`verified/kill-ai-slop-ndm-pro-focused.jpg`。

## ScribeStudio · 确认需要清理

### 06 · 用渐变制造“氛围”

- `desktop/renderer/styles.css:39`：页面顶端白色渐变没有表达内容。
- `desktop/renderer/styles.css:65`：command bar 顶光只是装饰。
- `desktop/renderer/styles.css:235-237`：拖放区同时叠网格和三层背景，视觉用力过度。
- `desktop/renderer/styles.css:384-387`：主按钮把渐变和大阴影同时打开。
- `desktop/renderer/styles.css:504-506`：媒体空状态同时叠网格与径向光晕。
- `desktop/renderer/styles.css:651`：转写头部再加一层纸色渐变。
- 建议：画布与 pane 使用实色；深度只由 1px hairline、内容黑场和必要的层级差形成；主按钮用一个实色。

### 10 · 每个区块都有英文 kicker

- `desktop/renderer/index.html:42` Source
- `desktop/renderer/index.html:67` Recipe
- `desktop/renderer/index.html:124` Delivery
- `desktop/renderer/index.html:155` Preview
- `desktop/renderer/index.html:178` Files
- `desktop/renderer/index.html:188` Run
- `desktop/renderer/index.html:201` Transcript
- 建议：删除重复英文层；只保留“会话素材 / 识别配方 / 逐段文本”等真正的中文标题。只有时码、格式等天然技术字段使用英文。

### 12 · 字号层级偏平、整体偏小

- `desktop/renderer/styles.css:112` 与 `:203` 使用 10px 标题/标签；正文和标题之间只差少量字号。
- 运行截图中左侧大量控件密度高，但右侧空状态巨大，视觉权重与任务重要性相反。
- 建议：删除一档微型字号；标签 ≥12px、正文 ≥14px，页面标题与区段标题依靠尺度和间距拉开，不靠铜色/大写补层级。

### 23 · 流程、状态、提示同时胶囊化

- `desktop/renderer/index.html:25` flow meter
- `desktop/renderer/index.html:33` status pill
- `desktop/renderer/styles.css:216` recipe hint 使用 999px 圆角
- 建议：状态 pill 作为真实状态信号可保留一个；流程改为扁平步骤/分段控件；“中文优先”移入字段值，不再做徽章。

### 30 · 工作区被切成太多同权卡片

- `desktop/renderer/index.html:40,64,121` 三个 dock section
- `desktop/renderer/index.html:175,185,198` files/log/transcript surfaces
- `desktop/renderer/styles.css:174-176` 三类 surface 共用相同卡片语法
- 建议：改为稳定 splitter panes：输入/配方是一个连续控制栏，媒体是主舞台，文本是连续阅读面；低频日志与输出进入次级 drawer。

## NDM · 确认需要清理

### 12 · 关键标签过小

- `Sources/NDMApp/MainWindowController.swift:2564` 详情标题仅 10pt。
- `Sources/NDMApp/ProgressWindowController.swift:398` 状态 caption 仅 9.5pt。
- `Sources/NDMApp/UpgradeWindowController.swift:172,188` Pro eyebrow/附加解锁信息为 10.5pt。
- 建议：建立共享 UI type scale；功能标签从 12pt 起，减少 9.5/10/10.5/11 的连续微差。窗口不整体机械放大，只重排内容密度和层级。

### 18 · 淡色图标 tile 成为弹窗默认模板

- `Sources/NDMApp/UpgradeWindowController.swift:156-169` accent pastel icon well。
- `Sources/NDMApp/MediaAccessPrompt.swift:178-191` 权限弹窗再次使用同构 badge tile。
- 建议：Pro 页只保留一个真正的产品/权益视觉锚点；权限页直接使用系统符号与标题对齐，不再每个弹窗先放一个彩色圆角方块。

### 30 · Inspector 与设置存在容器套层倾向

- `Sources/NDMApp/MainWindowController.swift:2516-2543` audio / diagnostic / tuning 各自再包 ChromeBox。
- `Sources/NDMApp/SettingsWindowController.swift:869-910` 每个设置分组都由同构 card + icon + title + subtitle 生成。
- `Sources/NDMApp/UpgradeWindowController.swift:205-210` 强调色 hero card 内又包含 icon well 与文字 stack。
- 建议：Inspector 改为连续信息面，仅对真正可操作/可折叠的模块加边界；设置页用分组标题 + 原生 form rows，不把每类设置包装成“产品卡”。

## 明确保留的设计选择 / 假阳性

- NDM 文件行的淡色类型背景、封面/应用图标预览是用户明确提出的识别与美观设计。它有信息意义，不按 slop 删除；仅控制不透明度与文字可读区。
- `QuietFinderRows.swift:114-168` 的 ambient artwork 是有品牌/内容来源的文件视觉，不是通用 CSS 氛围渐变；当前 flat scrim 已避免多段渐变，保留。
- BetterNDM `site-adapters.js:161,165` 的 X/YouTube 圆形按钮是在匹配目标站点原生控件形状，属于被防守的站点适配，不按 max-radius 清理。
- NDM README 的 ✅ 是工程状态文档，不是产品 UI 文案，扫描命中不处理。
- 三方向原型扫描命中的 Mac traffic lights、真实播放控件、方向编号和文件计数均有语义，属于假阳性。

## 汇总

- ScribeStudio：5 组确认问题。
- NDM：3 组确认问题。
- 自动扫描假阳性已单独列出，正式修复不会一键扫平用户刻意设计。
- 建议在方向选定后对以上 8 组全部应用；若某一组需要保留，可单独排除。
