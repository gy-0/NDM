# 功能清单（NDM 宿主）

状态：`[ ]` 未做 · `[~]` 进行中 · `[x]` 完成 · `[-]` 明确不做/延后

## A. 核心下载

| ID | 功能 | 状态 | 备注 |
|----|------|------|------|
| A01 | HTTP / HTTPS 下载 | [x] | `DownloadEngine` 主路径 |
| A02 | FTP 下载 | [x] | PASV+RETR+REST；支持 FTP HTTP CONNECT 代理 |
| A03 | 动态分段（Range） | [x] | 多连接 Range；直接迁移旧版普通 HTTP 的 `0x3A000` 规划量子、`0x32000` 可拆父段阈值和按每个未完成区间计算 worker capacity 的公式；连接数只是上限，现代回本模拟还会阻止二分出无法覆盖 TCP/TLS 成本的小叶段 |
| A04 | 暂停 / 继续 | [x] | Pause 保留 `seg.xN`；Start 续传 |
| A05 | 崩溃后续传 | [x] | 加载 `segments.bin` + 部分段；恢复前验证完整覆盖、唯一 segment ID、链表、远端总长和真实段文件大小，损坏/过期/超长临时段会隔离并安全重下 |
| A06 | 运行中改连接数 | [x] | Apply 会取消当前 Range 轮次、等待 FileHandle 收口、按真实落盘进度重切未完成区间并以新并发数发起请求；`testApplyConnectionsReplansActiveRangeTransfers` 验证真实 Range 数增加、最终字节一致与 DB 保留新连接数。 |
| A07 | 运行中限速 | [x] | 全局+每任务 bytes/s |
| A08 | Link Rescue 过期授权恢复 | [x] | 有来源页时打开浏览器继续；同页新捕获的 URL / Cookie / UA 自动认领原失败任务，保留任务 ID、文件名与 `seg.xN`；双轨媒体要求新视频/音频成对刷新；无来源页仍可手动 Renew URL |
| A09 | 多任务队列（同时/逐个） | [x] | `downloadAllAtOnce` |
| A10 | 最大连接数全局设置 | [x] | Settings |
| A11 | POST / 自定义 Header | [~] | 自定义 Header 已透传；桥协议与数据库会保留 POST method/body，但当前普通 HTTP 传输仍固定发 GET，需完成真实 POST Range/回退与认证测试后才能标记完成 |
| A12 | Cookie / 页面 Referer 元数据 | [x] | 桥接 |
| A13 | 自定义 User-Agent | [x] | |
| A14 | 文件大小探测与 resumable 检测 | [x] | HEAD → Range GET；Range 必须返回匹配的 206 / Content-Range / body 长度与同一远端总长，服务器忽略 Range 时取消响应并自动回退一次干净单流 GET，禁止把整文件追加进部分段或混合远端不同版本 |

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
| C05 | 播放列表 / 课程 / 合集批量下载 | [x] Collection Lens 识别合集元数据；当前/整合集范围；独立任务顺序排队、失败隔离与重启续队 |
| C06 | 站点级画质 / 容器 / 字幕偏好记忆 | [x] 本机仅保存规范化站点与交付选择；精确档位可用时静默恢复，缺失时回退推荐画质并关闭不可用字幕；不保存 URL、标题、Cookie 或内容 ID |
| C07 | 在线视频连续进度与真实后处理阶段 | [x] 字节计数与整体旅程分离；下载占 0–96%，真实 postprocessor 事件推进合并、字幕与最终整理，成功退出才到 100%；列表、详情、双进度条与 Dock 读取同一单调 fraction |
| C08 | Ready Choice 同站点安全一键下载 | [x] 只复用精确存在的上次画质/容器/字幕，并要求单视频、非重复任务和 Space Confidence=comfortable；否则保留完整画质与空间确认；主操作旁仅增加一个扁平“选项…”入口 |

## D. 任务管理与存储

| ID | 功能 | 状态 |
|----|------|------|
| D01 | SQLite 任务持久化 | [x] |
| D02 | 按状态分类 Complete / Incomplete | [x] 主窗侧栏 Status：All / Active / Queued / Paused / Completed / Failed（含计数） |
| D03 | 按类型 Video / Document / … | [x] 侧栏 Type 分组：Video / Audio / Document / Compressed / App / Image + 搜索 |
| D04 | 分类子文件夹 | [x] |
| D05 | 删除任务（可选删文件） | [x] 确认框：Remove Task / Remove & Trash File |
| D06 | 任务属性面板 | [x] |
| D07 | 默认下载目录 | [x] |
| D08 | 导入/兼容既有实现 DB（可选） | [x] `LegacyDBImporter` + 设置入口 |
| D09 | 下载前磁盘空间把握与峰值保护 | [x] 视频单项/合集按画质估算最终体积与合并空间；普通分段文件在真实大小探测后、传输前检查临时分段+成品峰值；识别断点续传、已有目标文件与跨磁盘场景 |

## E. UI / UX（Mac）

| ID | 功能 | 状态 |
|----|------|------|
| E01 | 主窗口任务表 | [x] 第三版 Quiet Finder 主窗：62pt 自定义工具带 + 215–268pt 侧栏 + 任务列表 + 可折叠 inspector；行内真实总进度/速度/ETA/状态；双击与右键语义；可测试 `TaskPresentation` |
| E02 | 新建 URL 窗口 | [x] Toolbar New / Alert |
| E03 | 下载进度窗口（总进度+逐连接进度） | [x] 每条 Range 连接独立显示真实 `completed / length`、百分比、字节区间与状态；连接列表可滚动；支持运行中改连接数 / Renew；inspector 摘要复用同一 `SegmentState` |
| E04 | 设置窗口 | [x] General / Browser / Network / Advanced 分页；代理与导入既有实现 DB |
| E05 | 菜单栏常驻（Agent） | [x] |
| E06 | 完成对话框 | [x] `Open` 为默认主操作；另有 `Show in Finder` 与 `Close`，文件缺失时禁用无效操作 |
| E07 | 错误对话框 | [x] 失败任务支持 Retry / Renew URL；列表与 inspector 展示错误文案 |
| E08 | 退出确认 | [x] 有活跃下载时提示 |
| E09 | Drag & Drop 链接/文件 | [x] URL/文本拖入主列表区，带 hover 高亮 |
| E10 | 浏览器引导窗口 | [x] `BrowsersWindowController` |
| E11 | About | [x] |
| E12 | Magic Inbox 剪贴板分享入口 | [x] 软件激活时只检查新 `changeCount` 的本地文本；抖音/小红书/B 站/YouTube/TikTok 口令显示来源明确的扁平工具带操作；重复任务和无关文本不打扰，点击后进入同一 Link Lens 确认链 |

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
| G02 | 单元测试（分段/URL/DB） | [x] 4125 精确边界、旧版阈值/容量公式、动态扩展、稳定 ID、连续覆盖、无重复 ID/断链/缝隙恢复计划、不可盈利叶段收敛、失败子段回并 |
| G03 | 集成测试（本地 HTTP 服务器） | [x] 多连接+运行中 2→4 热重规划+续传+Range 被忽略的安全单流回退+损坏/超长恢复段清理+短尾/长尾+自动抢尾一次或持续 416 rollback+初始 416 仍致命+远端代际变化禁止混合+HLS+FTP+NTLM+Bridge |
| G04 | 行为与协议说明 | [x] 见 `BridgeProtocol.swift` / 本表；研究档案不在本干净树 |
| G05 | 独立 Bundle ID（不覆盖既有实现） | [x] `dev.ndm.open` |
| G06 | 视频工具链零配置发行门禁 | [x] 官方 yt-dlp/Deno + 签名源码构建 FFmpeg；嵌套签名、许可证、哈希/架构清单、无外部 dylib、空 PATH 自检与真实 YouTube 下载测试 |

## 里程碑

1. **M0** 工程骨架 + 文档 — ✅
2. **M1** 单连接 HTTP + DB + 主窗口 — ✅
3. **M2** 多连接分段 + 暂停续传 + 进度窗 — ✅
4. **M3** 设置 / 代理 / 认证 / 限速 — ✅（含 NTLMv2 / FTP 代理 / Proxy Basic）
5. **M4** WebSocket 桥 + BetterNDM 联调 — 🟡 Wait 窗 + ShowPanel + WS 集成测试完成；`docs/BETTERNDM_SMOKE.md` 实机清单待人工走完
6. **M5** HLS + 媒体合并 — ✅ C01–C03（C04 由 BetterNDM 面板负责）
7. **M6** 打磨 UX、对等验收、打包 — 🟡 菜单快捷键、菜单栏状态、删除进废纸篓、Wait/Properties 文案已补；BetterNDM 实机与长期稳定性仍需继续

## 实现备注

- `DownloadEngine`：单连接引导后扩展多 Range；运行中改连接数会取消旧轮次再重规划。
- 收尾采用成本感知的动态偷尾：大连接池在活跃数降至 75% 后评估，小连接池等到半数空闲；只有剩余字节与预计耗时足以抵消取消和 TCP/TLS 重连成本时才补连接。真实 Range 集成测试同时覆盖“短尾不重连”和“长慢尾继续拆分”。自动创建的临时子段若收到 416，会像旧版一样并回相邻父段、保留其他落盘进度并关闭本任务后续自动偷尾；初始/手动 Range 与远端总长变化不允许进入该恢复分支。
- 分段 ID 在重规划时保持稳定，避免 `segments.bin` 与磁盘 `seg.xN` 错位。
- Range 响应必须与请求边界逐字节一致；旧轮次取消后排队中的进度回调会被丢弃，避免复用 segment ID 时污染新计划。
- 合并使用定长流式复制，段文件必须与计划长度完全相等；进度回调降频且单调。
- 主窗：`TaskPresentation` + 自定义扁平工具带 + 三栏 `NSSplitViewController`。

## 已知缺口

- 当前验证成品为 Apple Silicon 架构；Intel / Universal 发行物仍需在 x86_64 构建机上生成对应 App、Deno 与 FFmpeg 后合并验证。
- 本地打包使用 ad-hoc 签名完成结构验证；正式分发仍需 Developer ID 签名与 Apple 公证凭据。
- BetterNDM 实机 Chrome 联调按 `docs/BETTERNDM_SMOKE.md` 手工走。
- 菜单栏长时稳定性需在真实交互下继续观察。
- 真实购买地址与更新通道仍需上线；未配置购买地址时产品不会打开假链接。
- Onboarding 第 2 步测试文件指向 thinkbroadband 公共文件，正式版应换自有 CDN。
- 新 UI（诊断卡 / smartline / 清晰度 Sheet / 完成卡 / 菜单栏面板 / Onboarding / Pro 页）已过编译与逻辑测试，视觉走查需真机人工过一遍。
