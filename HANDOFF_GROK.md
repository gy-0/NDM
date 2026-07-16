# Grok 接手说明：NDM Swift 宿主与现代化产品方向

更新时间：2026-07-16（Asia/Singapore）  
仓库：`/Users/gaoyuan/NDM`  
当前数据目录：`~/Library/Application Support/dev.ndm.open`  
浏览器桥：`ws://127.0.0.1:10007/download`，子协议 `neatextension.v1`

---

## 0. 给 Grok 的一分钟版本

这是一个 clean-room Swift 下载器宿主，底层能力参考 Neat Download Manager 1.3，Chrome 扩展继续使用 BetterNDM。

用户的**最新产品方向**不是复制原版 UI：

- 原版只作为下载能力和行为基线；
- 保留多连接、断点续传、浏览器接管、HLS/FTP/认证等强能力；
- 界面和交互要重新设计成现代、成熟、有设计感的 macOS 下载器；
- 用户已经明确说过：**不要继续生成设计图片，直接改实际 Swift App**。

当前引擎、桥、完成弹窗、逐连接进度，以及**主窗口现代化重构**已经落地。下一块高价值工作是设置窗分组、类型过滤并入侧栏、以及产品完整性打磨（错误 Retry、键盘导航等）。不要再做概念图。

接手先执行：

```bash
cd /Users/gaoyuan/NDM
lsof -nP -iTCP:10007 -sTCP:LISTEN   # 启动宿主前确认原版没有占端口
swift test
```

最后一次干净构建结果：**56 个 XCTest 全绿**（NDMEngine 12、NDMCore 40、NDMBridge 4）。

---

## 1. 必读顺序

1. `HANDOFF_GROK.md`（本文）
2. `docs/FEATURE_PARITY.md`
3. `SESSION_REPORT.md`
4. `reverse/specs/10_GAPS.md`
5. `reverse/specs/03_ENGINE.md`
6. `reverse/specs/07_BROWSER_PROTOCOL.md`
7. `docs/BETTERNDM_SMOKE.md`

旧的 `HANDOFF_CODEX.md` 仍有大量有效技术上下文，但其中“先复制原版体验再增强”的措辞是旧方向；以本文和用户最新表述为准。

---

## 2. 不可违反的约束

- 只做 Swift 宿主：`NDMCore` / `NDMEngine` / `NDMBridge` / `NDMApp`。
- Chrome 扩展继续用 `reverse/extension/BetterNDM/`，不要逆向或复制原版扩展。
- 不覆盖原版数据：只能使用 `~/Library/Application Support/dev.ndm.open`。
- 未经用户要求，不要 `git commit` / `git push`。
- 涉及桥接端口时，先确认原版 Neat 没有占用 `127.0.0.1:10007`。
- 每轮代码修改后必须跑 `swift test`。
- 中文向用户汇报。
- UI 方向：保留能力，不复制原版陈旧 UI；不要再生成图片或视觉概念稿，直接落实际 macOS UI。

---

## 3. 这整个对话做了什么

### 3.1 建立 P0 行为基线

- 按顺序读了 `HANDOFF_CODEX.md`、`FEATURE_PARITY.md`、`10_GAPS.md`、`03_ENGINE.md`、`07_BROWSER_PROTOCOL.md`。
- 基线 `swift test` 原本为 48 个测试全绿。
- 只读分析了原版 `com.NeatDownloadManager` 数据目录下约 774 个可用 `LogFile.txt` 样本，没有写原版数据。

### 3.2 收紧动态分段 G01

原版 fixture 4125 的关键数据：

- 总长度：`18,207,337`
- 第一连接在第二连接切入时已下载：`983,040`
- 第二 Range 起点：`9,595,188`

闭合出的 clean-room 公式：

```text
secondStart = completedPrefix + (totalBytes - completedPrefix) / 2
            = 983040 + (18207337 - 983040) / 2
            = 9595188
```

实现策略：

- 新任务先用一个连接做确定性 bootstrap；
- 后续连接递归切分最大的未完成区间（tail-steal 模型）；
- 重规划时保留已有 `segmentId` 和 `seg.xN` 文件名；
- `nextId` 指向真实的下一个 segment ID，避免“元数据改编号、磁盘文件没迁移”的错位。

### 3.3 让运行中改连接数真正影响传输

原实现风险是只改 `segments.bin`，当前 URLSession 连接并没有变化。

现在 `applyConnections` / `applyConnectionsCount` 会：

1. 持久化新的连接数；
2. 增加 plan generation；
3. 主动取消当前 Range 下载轮次；
4. 等待 URLSession task 和 FileHandle 真正收口；
5. 按 `seg.xN` 的实际落盘长度重规划未完成区间；
6. 用新的 worker 上限重新发出真实 Range 请求。

集成测试实际验证 2→4：新 Range 请求出现、最终文件逐字节一致、DB 保留 4、日志包含 live replan。

### 3.4 稳定性和 exit 139

检查了两份历史崩溃报告：

```text
/Users/gaoyuan/Library/Logs/DiagnosticReports/Retired/NDM-2026-07-16-200216.ips
/Users/gaoyuan/Library/Logs/DiagnosticReports/Retired/NDM-2026-07-16-210003.ips
```

两份都是主线程 `EXC_BAD_ACCESS/SIGSEGV`，栈经过：

```text
MenuBarClientCore -> SerialExecutor._isSameExecutor -> Swift MainExecutor
```

地址均接近 `0x7c8`，系统为 macOS 27 beta。

已做防护：

- `AppDelegate` 显式延长到整个 AppKit run loop；
- 状态栏菜单项都有明确 target；
- 退出检查从主线程 semaphore 改为 `.terminateLater` + async reply；
- Wait 窗口 continuation 只能完成一次；
- Progress 窗口关闭即取消 polling；
- Bridge 状态在专用队列串行化；
- URLSession 取消能主动打断停滞 task；
- FileHandle 在 continuation 恢复前关闭；
- 合并改为 1 MiB 流式复制，避免一次载入大段 Data。

修复版曾连续运行 3 分 36 秒未复现，超过两份历史崩溃各自约 2:31 / 3:16 的运行时间。但因为栈位于系统私有框架，不能宣称 macOS 27 beta 根因 100% 消失。

### 3.5 桥接收紧与验收材料

- Bridge 明确只绑定 `127.0.0.1`，不再监听 `*`。
- 支持拆包 HTTP Upgrade，保留 header 后多余数据。
- 只有 WebSocket 101 成功后才上报 client count，避免初始 ShowPanel 污染握手。
- 限制 WebSocket 声明 payload 和 receive buffer。
- connection 表、broadcast、stop 全部串行。
- 自动测试覆盖 `waiting` / `nowaiting` / task created / ShowPanel / 并发 broadcast+stop。
- `reverse/tools/ws_bridge_client.py` 增加 `--listen-only`、`--expect-flow`、`--expect`、`--timeout`、`--max-replies`。
- BetterNDM 的 8 步手工 smoke 在 `docs/BETTERNDM_SMOKE.md`。

注意：当前系统 Python 运行 `ws_bridge_client.py` 时提示缺少 `websockets`。脚本本身 `--help` 和 `py_compile` 正常；如要实际连接，需要先在合适环境安装依赖，或直接用 BetterNDM 做 smoke。不要假装该依赖已安装。

### 3.6 用户对产品方向的修正

用户先批评当前软件和 UI 很不成熟，随后明确：

- 不要抄原版界面；
- 原版界面老旧，只拿它的强大下载底层做基础；
- 要 build 一个更有设计感、更完善的现代下载器；
- 不要继续生成设计图片。

对话中曾生成过三张视觉概念图，但没有写入仓库，用户随后明确终止这条路线。Grok 不要继续做图片方案，除非用户再次明确要求。

### 3.7 两个用户点名的 UX 缺陷已经直接修复

#### 下载完成弹窗

旧行为：只有 `OK`，以及条件式 `Show in Finder`，没有正常的“打开文件”。

新行为：

- `Open` 是默认主操作；
- `Show in Finder` 是第二操作；
- `Close` 可用 Escape 关闭；
- 文件不存在时禁用无效的 Open/Finder；
- Open 失败时提供 Finder fallback。

#### 每连接真实进度

旧行为：每个 segment 只是一个纯色块——绿=完成、蓝=进行中、灰=未开始；这不是进度条。

新行为：

- 总进度和每连接进度分开；
- 每条 Range connection 有独立 `NSProgressIndicator`；
- 显示连接编号、真实 `completed / length`、百分比、Range 起止、状态；
- 连接按 1、2、3……稳定排序；
- 列表可滚动并默认从 Connection 1 开始；
- 状态不只靠颜色，也有文字；
- 窗口可缩放，连接列表随窗口伸展。

现场用本地慢速 Range server 做过真实下载：总进度约 26% 时，16 条连接出现不同的真实百分比（连接 1 约 47%，其余约 24–25%）；完成弹窗实际出现 Open / Show in Finder / Close。验证任务和临时下载已经从 `dev.ndm.open` 数据库及原位置清理。

---

## 4. 本对话确认修改或新增的文件

仓库目前从 Git 视角几乎所有文件都是 `??` 未跟踪，普通 `git diff` 无法可靠区分“对话前”和“对话后”。下面清单来自实际代码、mtime、测试和会话记录交叉核对。

### NDMCore

| 文件 | 修改内容 |
|---|---|
| `Sources/NDMCore/Segments/SegmentFileFormat.swift` | 4125 动态首切公式；递归最大区间切分；运行时重规划保留 segment ID、已完成前缀和真实 nextId |
| `Sources/NDMCore/Models/DownloadProgress.swift` | `SegmentState.fractionCompleted`、`remainingBytes`，供每连接真实进度 UI 使用 |
| `Sources/NDMCore/Models/DownloadTask.swift` | `destinationFileURL`，统一完成文件的 Open/Finder 路径 |

### NDMEngine

| 文件 | 修改内容 |
|---|---|
| `Sources/NDMEngine/DownloadEngine.swift` | 单连接 bootstrap；动态扩展；plan generation；运行中取消/重规划/重发；单调进度；真实 Range 日志；流式 merge |
| `Sources/NDMEngine/CancelToken.swift` | 可注册/移除 cancellation handler，取消时主动打断 URLSession task |
| `Sources/NDMEngine/RangeStreamDownloader.swift` | 管理实际 data task；single-resume finish；关闭 FileHandle 后再恢复 continuation；取消 handler；进度回调降频 |
| `Sources/NDMEngine/DownloadManager.swift` | `applyConnections` 真正调用 live replan；完成/失败时重新读最新 DB task，避免旧快照覆盖运行中连接数修改 |
| `Sources/NDMEngine/FTPEngine.swift` | async 环境下锁访问改为 `withLock`，清理编译器并发警告 |

### NDMBridge

| 文件 | 修改内容 |
|---|---|
| `Sources/NDMBridge/BrowserBridge.swift` | 仅监听 loopback；Bridge 状态串行；Upgrade 拆包；握手后才 client-ready；payload/buffer 上限；并发 stop/broadcast 安全 |

### NDMApp

| 文件 | 修改内容 |
|---|---|
| `Sources/NDMApp/main.swift` | `withExtendedLifetime(delegate)`，避免 AppDelegate 过早释放 |
| `Sources/NDMApp/AppDelegate.swift` | 显式 menu target；非阻塞 terminate；bridge stop；初始 ShowPanel；Wait 的 waiting/nowaiting；完成弹窗 Open/Finder/Close |
| `Sources/NDMApp/WaitWindowController.swift` | NSWindowDelegate；红点关闭等价取消；one-shot finish，防 continuation 悬挂/双恢复 |
| `Sources/NDMApp/ProgressWindowController.swift` | 关闭 polling；运行中 Apply 文案；整体进度 + 每连接真实进度条、Range、字节、状态、滚动和稳定排序 |
| `Sources/NDMApp/SettingsWindowController.swift` | `allowedContentTypes` 替代弃用的 `allowedFileTypes` |

### 测试

| 文件 | 修改或新增内容 |
|---|---|
| `Tests/NDMCoreTests/SegmentDynamicPlanTests.swift` | 4125 精确边界、32 段连续覆盖、最小段约束、稳定 ID 重规划 |
| `Tests/NDMCoreTests/DownloadPresentationTests.swift` | 每连接 fraction/remaining clamp；完成文件 URL |
| `Tests/NDMEngineTests/LocalRangeServer.swift` | 延迟响应、线程安全记录 Range header |
| `Tests/NDMEngineTests/DownloadEngineIntegrationTests.swift` | 运行中 2→4 连接热重规划，验证真实请求变化和最终字节一致 |
| `Tests/NDMBridgeTests/BrowserBridgeIntegrationTests.swift` | waiting/nowaiting/task、真实 ShowPanel frame、并发 broadcast/stop |

### 工具和文档

| 文件 | 修改或新增内容 |
|---|---|
| `reverse/tools/ws_bridge_client.py` | 可执行桥接验收参数和依赖友好提示 |
| `docs/BETTERNDM_SMOKE.md` | 8 步 BetterNDM 手工验收清单 |
| `docs/FEATURE_PARITY.md` | A03/A06、桥、稳定性、逐连接进度、完成动作和 residual gaps |
| `HANDOFF_CODEX.md` | 本会话技术进度；部分旧产品措辞由本文覆盖 |
| `SESSION_REPORT.md` | 中文交付摘要、验收命令、51 测试、残余缺口 |
| `HANDOFF_GROK.md` | 本交接文档 |

### 主窗口现代化（已完成）

| 文件 | 修改内容 |
|---|---|
| `Sources/NDMCore/Presentation/TaskPresentation.swift` | 新增：`SidebarFilter`、`TaskRowPresentation`、格式化与 selection actions |
| `Sources/NDMApp/MainWindowController.swift` | 重写：Toolbar + Split（侧栏/列表/inspector）+ 真实进度行 + 右键/双击 |
| `Tests/NDMCoreTests/DownloadPresentationTests.swift` | 新增侧栏/进度文案/Open/搜索/enablement 测试 |

---

## 5. 主窗口当前状态（重构后）

已落地的结构：

1. 原生 `NSToolbar`：New / Start / Pause / Search / Browsers / Settings。
2. `NSSplitViewController`：All/Active/Queued/Paused/Completed/Failed 侧栏（含计数）+ 任务列表 + 可折叠 inspector。
3. 主列表每行：文件名、状态·host、总进度条与百分比、大小/速度/ETA；失败显示错误文案。
4. 双击：完成→Open；活跃→Progress；暂停/失败→Start。右键含 Open/Finder/Start/Pause/Progress/Properties/Delete。
5. Inspector 复用同一 `SegmentState` 摘要，不另造假数据。

仍可继续打磨：行内 hover-only 操作按钮、类型过滤并回侧栏、键盘导航、设置窗分组。

---

## 6. 推荐下一步接手顺序

### 第一阶段（已完成）：主窗口重构

见第 5 节。

### 第二阶段：补产品完整性

- 错误状态加 Retry/Renew URL 入口；
- 行内 hover 主操作按钮；
- 类型过滤（Video/Document）并入侧栏或智能搜索；
- 支持更完整键盘导航；
- 设置窗口重新分组，而不是一长列字段；
- 统一剩余英文 raw 文案（设置/属性窗）。

### 第三阶段：继续行为对等和实机验收

- 按 `docs/BETTERNDM_SMOKE.md` 跑真实 Chrome；
- 比较运行中 8→32、32→2 的原版/当前 LogFile；
- 持续观察 macOS 27 beta 下 MenuBarClientCore 崩溃；
- 后续再处理 MKV G07/G11、HLS G06。

---

## 7. 当前已知 residual gaps

- 原版 socket 1 使用开放 `Range: 0-`，切分时刻受真实 TLS/RTT/吞吐影响；当前实现用确定性 bootstrap，公式和 4125 边界对齐，但触发时序不完全相同。
- segment merge/rollback 的逐事件顺序未完全复刻。
- BetterNDM 的 Chrome webRequest、Cookie、媒体捕获仍缺一次完整人工 smoke。
- exit 139 的高风险代码已防护，但 macOS 27 beta 私有框架根因仍需长时间观察。
- MKV G07/G11、HLS G06 延续旧缺口。
- 主窗口骨架已现代化；设置窗口分组与类型侧栏仍是产品短板。

---

## 8. 验收命令与当前真实状态

```bash
cd /Users/gaoyuan/NDM

# 全量测试
swift test

# 热重规划
swift test --filter testApplyConnectionsReplansActiveRangeTransfers

# 桥接
swift test --filter BrowserBridgeIntegrationTests

# Python 工具静态检查和逆向规格测试
PYTHONPYCACHEPREFIX=/tmp/ndm-pycache python3 -m py_compile reverse/tools/ws_bridge_client.py
PYTHONPYCACHEPREFIX=/tmp/ndm-pycache python3 -m unittest reverse/tools/test_re_specs.py

# 启动前端口检查
lsof -nP -iTCP:10007 -sTCP:LISTEN

# 启动
swift run NDM
```

最后一次检查：

- 主窗重构后 `swift test`：**56/56** 通过（Core +5 presentation）；
- `:10007` 启动前无原版占用；
- 未 commit/push。

用于复现逐连接 UI 的临时慢速 Range server 保存在项目外：

```text
/Users/gaoyuan/Documents/Codex/2026-07-16/goal-users-gaoyuan-ndm-swift-neat/work/ndm-ui-validation-20260716-2221/slow_range_server.py
```

旁边的 `NDMPreview.app` 是验收时的临时包，可能落后于最终源码，不要当成发布产物；需要时重新 `swift build`。

---

## 9. Git 和原版 App 的注意事项

- `git status --short` 目前几乎整个仓库都是 `??`，说明没有可用的 tracked baseline；不要声称 `git diff` 能完整展示本会话修改。
- 不要为了“清理”执行 `git reset --hard`、`git checkout --` 或批量删除。
- 仓库内的 `NeatDownloadManager.app/` 和 `/Applications/NeatDownloadManager.app` 是原版/参考包，不要把 Swift 新宿主覆盖进去。
- 原版只用作 clean-room 行为观察，不要改原版数据库和偏好。

---

## 10. 可直接复制给 Grok 的启动提示词

```text
继续开发 /Users/gaoyuan/NDM。

先完整阅读：
1. HANDOFF_GROK.md
2. docs/FEATURE_PARITY.md
3. SESSION_REPORT.md
4. reverse/specs/10_GAPS.md

用户最新方向：原版 Neat Download Manager 1.3 只作为强大下载能力和行为基线，不复制它老旧的 UI。要把当前 Swift 宿主做成现代、成熟、有设计感且功能完善的 macOS 下载器。不要再生成图片或 mockup，直接修改实际 Swift App。

硬约束：
- 只做 NDMCore/NDMEngine/NDMBridge/NDMApp；扩展继续用 BetterNDM
- 数据目录保持 ~/Library/Application Support/dev.ndm.open
- 未要求不要 git commit/push
- 启动桥前确认原版没占 10007
- 修改后 swift test 全绿，中文汇报

当前引擎、运行中改连接数、桥稳定性、完成弹窗、逐连接进度、主窗 Toolbar/侧栏/列表/inspector 已经完成。不要重做这些。

现在直接做下一高价值工作：设置窗口分组重排 + 主列表错误 Retry/Renew + 类型过滤并入侧栏；保持 DownloadManager/DownloadEngine 行为不回退。不要生成图片。

完成后：
1. swift test
2. 实际启动检查 UI
3. 确认 10007 无冲突和无残留
4. 更新 docs/FEATURE_PARITY.md、SESSION_REPORT.md、HANDOFF_GROK.md
5. 汇报改了哪些文件、如何验收、还差什么
```

