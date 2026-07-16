# 功能对等清单（NDM 复刻）

状态：`[ ]` 未做 · `[~]` 进行中 · `[x]` 完成 · `[-]` 明确不做/延后

## A. 核心下载

| ID | 功能 | 状态 | 备注 |
|----|------|------|------|
| A01 | HTTP / HTTPS 下载 | [x] | `DownloadEngine` 主路径 |
| A02 | FTP 下载 | [x] | PASV+RETR+REST；支持 FTP HTTP CONNECT 代理 |
| A03 | 动态分段（Range） | [x] | 已对齐：先单连接引导；第二连接按“已完成前缀 + 剩余区间中点”偷尾，4125 的 983,040B 前缀精确得到 9,595,188 起点；其余连接递归切最大未完成区间；重规划保留 `seg.xN` ID。仍差：原版首请求是开放 `0-` 且按实时握手/吞吐触发，本实现为确定性测试使用有界 bootstrap；精确时序与 merge/rollback 启发式仍未逐事件相同。 |
| A04 | 暂停 / 继续 | [x] | Pause 保留 `seg.xN`；Start 续传 |
| A05 | 崩溃后续传 | [x] | 加载 `segments.bin` + 部分段 |
| A06 | 运行中改连接数 | [x] | Apply 会取消当前 Range 轮次、等待 FileHandle 收口、按真实落盘进度重切未完成区间并以新并发数发起请求；`testApplyConnectionsReplansActiveRangeTransfers` 验证真实 Range 数增加、最终字节一致与 DB 保留新连接数。 |
| A07 | 运行中限速 | [x] | 全局+每任务 bytes/s |
| A08 | 过期链接 Renew | [x] | 进度窗 Renew URL |
| A09 | 多任务队列（同时/逐个） | [x] | `downloadAllAtOnce` |
| A10 | 最大连接数全局设置 | [x] | Settings |
| A11 | POST / 自定义 Header | [x] | |
| A12 | Cookie / 页面 Referer 元数据 | [x] | 桥接 |
| A13 | 自定义 User-Agent | [x] | |
| A14 | 文件大小探测与 resumable 检测 | [x] | HEAD → Range GET |

## B. 代理与认证

| ID | 功能 | 状态 |
|----|------|------|
| B01 | HTTP Proxy | [x] URLSession proxy dict |
| B02 | HTTPS Proxy | [x] 与 HTTP 共用设置 |
| B03 | FTP Proxy | [x] HTTP CONNECT + Basic |
| B04 | SOCKS（版本可选） | [x] SOCKS4/5 via URLSession |
| B05 | Proxy Basic 认证 | [x] HTTP/SOCKS/FTP 凭据 UI + Proxy-Authorization |
| B06 | HTTP Basic / Digest / NTLM | [x] Basic+Digest+NTLMv2（Type1/2/3） |
| B07 | 凭据库（auths 表） | [x] CRUD + 按 host 匹配 |

## C. HLS / 媒体

| ID | 功能 | 状态 |
|----|------|------|
| C01 | m3u8 / HLS master 解析 | [x] |
| C02 | 下载全部 .ts 并合并 | [x] AES-128 + 分段断点续传 |
| C03 | 音视频分轨 → MKV 合并 | [x] `MKVMergeEngine`（双引擎 + ffmpeg/`c` copy；无 ffmpeg 时旁路落盘） |
| C04 | 浏览器探测到的多清晰度列表 | [-] UI 在 BetterNDM；宿主收最终 URL/`urla` |

## D. 任务管理与存储

| ID | 功能 | 状态 |
|----|------|------|
| D01 | SQLite 任务持久化 | [x] |
| D02 | 按状态分类 Complete / Incomplete | [x] 主窗侧栏 Status：All / Active / Queued / Paused / Completed / Failed（含计数） |
| D03 | 按类型 Video / Document / … | [x] 侧栏 Type 分组：Video / Audio / Document / Compressed / App / Image + 搜索 |
| D04 | 分类子文件夹 | [x] |
| D05 | 删除任务（可选删文件） | [x] |
| D06 | 任务属性面板 | [x] |
| D07 | 默认下载目录 | [x] |
| D08 | 导入/兼容原版 DB（可选） | [x] `LegacyDBImporter` + 设置入口 |

## E. UI / UX（Mac）

| ID | 功能 | 状态 |
|----|------|------|
| E01 | 主窗口任务表 | [x] 现代主窗：`NSToolbar` + 侧栏 + 任务列表 + 可折叠 inspector；行内真实总进度/速度/ETA/状态；双击与右键语义；可测试 `TaskPresentation` |
| E02 | 新建 URL 窗口 | [x] Toolbar New / Alert |
| E03 | 下载进度窗口（总进度+逐连接进度） | [x] 每条 Range 连接独立显示真实 `completed / length`、百分比、字节区间与状态；连接列表可滚动；支持运行中改连接数 / Renew；inspector 摘要复用同一 `SegmentState` |
| E04 | 设置窗口 | [x] General / Browser / Network / Advanced 分页；代理与导入原版 DB |
| E05 | 菜单栏常驻（Agent） | [x] |
| E06 | 完成对话框 | [x] `Open` 为默认主操作；另有 `Show in Finder` 与 `Close`，文件缺失时禁用无效操作 |
| E07 | 错误对话框 | [x] 失败任务支持 Retry / Renew URL；列表与 inspector 展示错误文案 |
| E08 | 退出确认 | [x] 有活跃下载时提示 |
| E09 | Drag & Drop 链接/文件 | [x] URL/文本拖入主列表区，带 hover 高亮 |
| E10 | 浏览器引导窗口 | [x] `BrowsersWindowController` |
| E11 | About | [x] |

## F. 浏览器扩展

| ID | 功能 | 状态 |
|----|------|------|
| F01 | 本地 WebSocket 桥 | [x] 仅监听 `127.0.0.1`；`/download` + `neatextension.v1`；真实文本帧测试覆盖 Waiting/nowaiting/ShowPanel；连接表与 broadcast/stop 在专用队列串行化。 |
| F02 | Chrome/Edge/Firefox 扩展 | [-] BetterNDM |
| F03 | Safari Web Extension | [-] 可选，非主线 |
| F04–F07 | 捕获/右键/浮动按钮/过滤 | [-] BetterNDM |

## G. 工程与质量

| ID | 功能 | 状态 |
|----|------|------|
| G01 | 可编译 macOS App | [x] |
| G02 | 单元测试（分段/URL/DB） | [x] 4125 精确边界、动态扩展、稳定 ID 重规划与连续覆盖 |
| G03 | 集成测试（本地 HTTP 服务器） | [x] 多连接+运行中 2→4 热重规划+续传+HLS+FTP+NTLM+Bridge |
| G04 | 与原版行为对照文档 | [x] `reverse/specs/` |
| G05 | 独立 Bundle ID（不覆盖原版） | [x] `dev.ndm.open` |

## 里程碑

1. **M0** 工程骨架 + 文档 — ✅
2. **M1** 单连接 HTTP + DB + 主窗口 — ✅
3. **M2** 多连接分段 + 暂停续传 + 进度窗 — ✅
4. **M3** 设置 / 代理 / 认证 / 限速 — ✅（含 NTLMv2 / FTP 代理 / Proxy Basic）
5. **M4** WebSocket 桥 + BetterNDM 联调 — 🟡 Wait 窗 + ShowPanel + WS 集成测试完成；`docs/BETTERNDM_SMOKE.md` 实机清单待人工走完
6. **M5** HLS + 媒体合并 — ✅ C01–C03（C04 由 BetterNDM 面板负责）
7. **M6** 打磨 UX、对等验收、打包 — 🟡 设置分页 / 类型侧栏 / Retry·Renew 已落地；BetterNDM 实机与长期稳定性仍需继续

## 本会话 P0 证据（2026-07-16）

- `SegmentFileFormat.planDynamicInitial` 用原版 4125 完整日志反推公式：`prefix + (total-prefix)/2`；测试与 fixture 边界逐字节一致。
- `DownloadEngine` 新下载执行单连接 bootstrap，再动态扩展；运行中 Apply 使用独立轮次取消 token，旧请求真正停止后才重规划与重发 Range。
- 重规划不再重编号既有 `segmentId`，因此不会出现“`segments.bin` 指向新 ID、磁盘仍是旧 `seg.xN`”的错位。
- 合并改为 1 MiB 流式复制，避免 `Data(contentsOf:)` 一次载入大段；URLSession 取消可主动打断停滞请求，进度回调降频且单调。
- 两份历史 NDM `.ips` 均为主线程 `MenuBarClientCore → Swift MainExecutor` 的 `EXC_BAD_ACCESS(0x7c8)`；已显式延长 `AppDelegate` 生命周期、设置状态栏菜单 target、移除主线程 semaphore 等待、保证 Wait continuation 只恢复一次，并串行化桥连接表。
- 主窗产品重构：`TaskPresentation`（NDMCore）承载侧栏过滤、状态文案、速度/ETA、按钮 enablement；`MainWindowController` 换成原生 Toolbar + `NSSplitViewController`（侧栏 / 列表 / inspector），主列表显示真实进度而不再是 `…`。

## 已知非阻塞缺口（规格 G01/G07/G11）

- 动态切分的**网络时序**仍非逐事件复刻：原版 socket 1 使用开放 `Range: 0-` 并在 socket 2 TLS 握手期间继续前进；本实现用确定性 bootstrap 后扩展。4125 边界公式已闭合，但不同 RTT/吞吐下的触发时刻及 merge/rollback 策略仍有差异。
- MKV 内建 muxer 未手写 EBML：优先 `ffmpeg -c copy`；无 ffmpeg 时视频主文件 + `.audio.*` 旁路
- BetterNDM 实机 Chrome 尚未由本会话自动操作；按 `docs/BETTERNDM_SMOKE.md` 手工 smoke。
- exit 139 的历史栈已定位并加防护，但 macOS 27 beta 私有 `MenuBarClientCore` 本身不可控；仍建议在真实菜单栏交互与长时下载下继续观察 DiagnosticReports。
