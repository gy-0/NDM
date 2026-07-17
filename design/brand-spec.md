# NDM · Brand Spec（Quiet Finder）
> 采集日期：2026-07-17  
> 资产来源：开源产品自研方向（无第三方品牌资产）  
> 资产完整度：部分（词标暂代 Logo；改名后替换）  
> 选定方向：**A · Quiet Finder**（Dieter Rams × Apple HIG）

## 核心资产

### Logo / 词标
- 当前：文案词标 **NDM**（SF / 系统 sans，semibold）
- 路径：无独立文件；UI 里直接用窗口标题与 About
- 使用场景：主窗标题、About、菜单栏
- 禁用：拉伸、加描边、换成装饰性 icon 堆
- 备注：**后续会改名**——所有用户可见字符串集中在 App 标题 / About / 菜单，避免硬编码散落

### UI 截图（数字产品）
- **主设计源：`design/NDM-Design-Suite.html`（精装版，覆盖主窗 / 进度 / 媒体闭环 / 诊断文案 / 菜单栏 / Onboarding / Pro，全部屏 + 落地映射表）**
- 早期基线：`design/NDM-Quiet-Finder.html`
- 方向对照：`design/NDM-UI-Directions.html`（A 已选）
- 工作名：**Pelican**（鹈鹕兜住大文件 = 多连接隐喻；定名前全局可替换）

### 新增组件 token（Design Suite 引入）
- 语义底色：`ok-soft` / `danger-soft` / `warn-soft`（诊断卡、行内状态）
- 组件：statgrid（进度窗四格统计）、smartline（智能连接数说明行）、diag card（诊断卡）、qopt（清晰度选项）、steps（Finalize 完成清单）、popover（菜单栏迷你面板）

## 辅助资产

### 色板（语义色优先 · 跟随系统）

| Token | Light | Dark | AppKit |
|---|---|---|---|
| Accent | 冷蓝 `#2563EB` | `#61A5FF` | `NDMChrome.accent` |
| Ink | `#14161A` | `#E8EAED` | `labelColor` |
| Secondary | `#5C6370` | `#8B919C` | `secondaryLabelColor` |
| Surface | `#F2F3F6` / `#F6F7FA` | `#1A1C20` / `#1E2024` | `NDMChrome.windowFill` / `contentSurface` |
| Sidebar | `#E8EBF0` | `#16181C` | `NDMChrome.sidebarFill` |
| Progress fill（列表/总进度） | Accent | Accent | `controlAccentColor` / 系统进度条 |
| Segments fill | `#2F9E6B` | `#2F9E6B` | `systemGreen` |
| Status Downloading | Accent 系 | Accent 系 | `systemBlue` |
| Status Completed | Green 系 | Green 系 | `systemGreen` |
| Status Failed | Red 系 | Red 系 | `systemRed` |

**禁用色**：紫渐变、赛博霓虹、多 accent 并存、暖米黄 / 奶油纸色（易显「黄不拉几」）。  
**表面原则**：冷中性蓝灰 + 不透明窗底（避免壁纸染色发黄）。

### 字型
- Display / UI：系统 `-apple-system` / SF Pro（工具感，不另引展示衬线）
- Mono（速度 / ETA / 百分比）：`monospacedDigitSystemFont`
- 进度窗大号百分比：40pt semibold

### 布局节奏
- 主窗：侧栏 168–240 · 列表 ≥420 · Inspector 260–360（可折叠）
- 列表行高 ≈ 72；左内边距 12
- 进度窗：宽 ≈ 520；信息卡圆角 10；分段条高 14–18
- 工具栏：Unified + iconAndLabel

### 签名细节（做到 120%）
- 进度窗：**大号百分比 + 状态 pill + 单色绿 Segments**
- 列表：文件名 semibold + 状态·主机 secondary + 细进度条
- 主题：**默认跟随系统**（Settings 可覆盖 Light / Dark）

### 禁区
- 不用 CSS/SVG 手画产品意象代替 UI
- 不在列表堆装饰 icon / stats 条
- 连接级细节只在 Progress 窗，不塞进主列表
- **AppKit 铁律：任何 layer 颜色必须走 `ChromeBox` / `updateLayer()`，严禁 `layer?.backgroundColor = xxx.cgColor` 直接快照**（外观切换会失效发灰）
- 侧栏必须保持系统毛玻璃材质透出（scrollView/tableView 全透明），不得用不透明色覆盖——否则标题栏红绿灯区出现割裂

### 气质关键词
克制 · 可信 · 系统感 · 安静 · 可改名友好
