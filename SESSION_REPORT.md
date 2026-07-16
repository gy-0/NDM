# 本会话交付报告（2026-07-16，主窗重构）

## 做了什么

在引擎/桥/进度窗已稳定的前提下，按用户最新方向（原版只做能力基线，不抄旧 UI）重构真实主窗口：

- 新增可测试 `Sources/NDMCore/Presentation/TaskPresentation.swift`：侧栏过滤、状态文案、进度/速度/ETA 格式化、双击主操作、toolbar enablement。
- 重写 `Sources/NDMApp/MainWindowController.swift`：
  - 原生 `NSToolbar`（New / Start / Pause / Search / Browsers / Settings）
  - `NSSplitViewController`：状态侧栏 + 任务列表 + 可折叠 inspector
  - 行内真实总进度条、百分比、大小、速度、ETA、失败文案
  - 双击：完成→Open，下载中→Progress，暂停/失败→Start
  - 右键：Open / Finder / Start / Pause / Progress / Properties / Delete
  - 拖放 URL 带 hover 高亮；inspector 复用 `SegmentState` 摘要
- 未改动 `DownloadManager` / `DownloadEngine` 下载行为。

## 如何验收

```bash
cd /Users/gaoyuan/NDM
lsof -nP -iTCP:10007 -sTCP:LISTEN   # 应无原版占用
swift test
swift run NDM
```

- 全量结果：**56** 个 XCTest 通过（NDMEngine 12、NDMCore **40**、NDMBridge 4）。
- 新增 presentation 单测覆盖侧栏匹配、实时进度文案、完成文件 Open、搜索、selection actions。
- 启动前确认 `:10007` 无监听；未 commit/push。

## Residual gaps

- 设置窗口仍是长表单，未分组重排。
- 类型过滤（Video/Document）尚未并回侧栏；当前以状态侧栏 + 搜索为主。
- BetterNDM Chrome 实机 smoke、MKV G07/G11、HLS G06、动态分段网络时序差异仍在。
- macOS 27 beta 下 MenuBarClientCore exit 139 仍需长时观察。
