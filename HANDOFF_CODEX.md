# Codex 接力说明（从 Cursor / Grok 会话移交）

> 目标读者：在 Codex 中继续本仓库工作的 Agent。  
> 仓库：`/Users/gaoyuan/NDM`  
> 用户最新意图：原版作为下载能力/行为基线，**不复制原版老旧 UI**；在强大底层上直接做现代、成熟的 macOS 下载器。  
> 策略：clean-room Swift 重写宿主；Chrome 扩展用 **BetterNDM**（不逆向原版扩展）。

---

## 0. 开场请先读这些

1. `docs/FEATURE_PARITY.md` — 功能勾选与已知缺口  
2. `reverse/specs/10_GAPS.md` — 逆向未闭合项（G01/G03/G06/G07/G11…）  
3. `README.md` — 工程入口  
4. 本文档 — 当前真实完成度与优先工作流  

验证：

```bash
cd /Users/gaoyuan/NDM && swift test
swift run NDM   # 桥 ws://127.0.0.1:10007/download ；勿与原版 Neat 同时开
```

数据目录（独立于原版）：`~/Library/Application Support/dev.ndm.open`

---

## 1. 诚实完成度（不要夸大）

| 层面 | 状态 |
|------|------|
| 宿主逆向规格 | **主路径已冻结**（`reverse/specs/00`–`14` + Ghidra dumps），但 **非 100% 穷尽** |
| Swift 宿主 | **主线可跑、测试较多**，行为级对等；**尚未达到原版体感/细节对等** |
| 扩展 | BetterNDM 副本在 `reverse/extension/BetterNDM/`；实机 Chrome smoke 仍缺 |

用户后续明确修正：既要补齐关键行为，也要直接提升真实 Swift App 的产品成熟度；不要再生成图片或照抄原版界面。

---

## 2. 已实现（Swift）

工程：`Package.swift` → `NDMCore` / `NDMEngine` / `NDMBridge` / `NDMApp`

- HTTP(S) 多连接 Range、`segments.bin` / `seg.xN`、暂停续传、限速  
- Digest + NTLMv2、Basic、auths 表  
- FTP（PASV/REST）+ FTP HTTP CONNECT 代理  
- HLS（master/media、TS 合并、AES-128、TS 断点）  
- MKV 双轨：`MKVMergeEngine`（ffmpeg `-c copy`；无 ffmpeg 旁路）  
- WS 桥 `/download` + `neatextension.v1`；Wait 窗；ShowPanel；集成测试  
- 设置（代理凭据、ShowPanel、Wait 确认）；主窗过滤；Browsers 引导；原版 DB 导入  
- 进度窗：改连接数、Renew URL  

测试：`Tests/NDMCoreTests`、`NDMEngineTests`、`NDMBridgeTests`（`swift test` 应全绿）。

---

## 3. 与原版仍有差距 — 优先打磨顺序

按「对等原版」优先，不要先做花活。

### P0 — 行为对等（最高优先）

1. **BetterNDM 实机联调**（关闭原版 Neat，独占 10007）  
   - waiting / nowaiting、Cookie、媒体捕获、ShowPanel  
   - 对照 `reverse/specs/07_BROWSER_PROTOCOL.md`  
2. **动态分段逼近原版（G01）**  
   - 用更多原版 `LogFile.txt` + `reverse/fixtures/segments/4125_*`  
   - 现状：已闭合 4125 的“已完成前缀 + 剩余中点”公式并实现单连接 bootstrap → 递归偷尾；网络触发时序仍非逐事件复刻  
   - 代码：`SegmentFileFormat.swift`、`DownloadEngine.swift`  
3. **运行中改连接数热更新真正生效（本会话已关闭）**  
   - Apply 会取消当前 URLSession Range 轮次、按落盘前缀重规划并以新 worker 上限重发请求；集成测试验证 2→4 真实 Range 变化  
4. **MKV 对等（G07/G11）**  
   - 抓 YouTube/adaptive 样本；确认 `urla` 何时出现  
   - 减少对 ffmpeg 依赖或固化「有/无 ffmpeg」行为与原版对比  

### P1 — UX / 稳定性

5. **崩溃（曾 exit 139）** — 两份 `.ips` 指向主线程 MenuBarClientCore/Swift executor；已做 delegate 保活、显式 menu target、桥串行化、Wait 单次 completion、异步退出检查；仍需 macOS 27 beta 长时观察  
6. **端口占用** — 原版占 10007 会冲突；已有 Continue Without Bridge，可再打磨提示  
7. **UI 分组/进度/错误文案** 对照 `reverse/specs/08_UI.md`  
8. **HLS 断点与原版日志对齐**（G06）  

### P2 — 明确后置

- Safari 扩展 `[-]`  
- 自写完整 EBML muxer（除非关掉 G07）  
- 与核心下载器无关的花哨功能；但主窗口、任务详情和完成流程的现代化已经获得用户明确授权  

---

## 4. 关键路径速查

| 区域 | 路径 |
|------|------|
| 规格 | `reverse/specs/` |
| Ghidra | `reverse/dumps/full_decompile/` |
| BetterNDM | `reverse/extension/BetterNDM/` |
| 桥 | `Sources/NDMBridge/BrowserBridge.swift` |
| 引擎 | `Sources/NDMEngine/DownloadEngine.swift` 等 |
| 编排 | `Sources/NDMEngine/DownloadManager.swift` |
| UI | `Sources/NDMApp/*` |
| 对等表 | `docs/FEATURE_PARITY.md` |
| WS 手工客户端 | `reverse/tools/ws_bridge_client.py` |

---

## 5. 工作约定

- 中文回复用户  
- **不要** 逆向原版 Chrome 扩展；扩展 = BetterNDM  
- **不要** 覆盖原版数据目录；用 `dev.ndm.open`  
- 改完跑 `swift test`；涉及桥时确认原版未占用 10007  
- 更新 `docs/FEATURE_PARITY.md` 勾选与备注  
- 未获要求不要 commit/push  

---

## 6. 建议 Codex 开场任务（用户离开约 1 小时）

```
1. 读 HANDOFF_CODEX.md + FEATURE_PARITY.md + specs/10_GAPS.md
2. swift test 确认基线
3. 当前 P0：按 `docs/BETTERNDM_SMOKE.md` 做 Chrome 实机；或补 8→32 / 32→2 原版日志对照；applyConnections 热更新已完成
4. 每完成一块更新 FEATURE_PARITY 并留下可复现的测试/对照说明
5. 用户回来前给出：做了什么、还差什么、如何手工验收 BetterNDM
```

---

## 7. 给用户贴进 Codex 的最短提示（可复制）

```
继续 /Users/gaoyuan/NDM 的 clean-room Swift 宿主复刻。
先读 HANDOFF_CODEX.md 与 docs/FEATURE_PARITY.md。
目标：先达到 Neat Download Manager 1.3 行为对等，再谈增强。
扩展用 BetterNDM，不逆向原版扩展。数据目录 dev.ndm.open。
优先 P0：BetterNDM 实机缺口、动态分段的真实网络时序对照；运行中改连接数热更新已完成。随后再看 MKV/urla。
改完 swift test；中文汇报。
```

---

## 8. 本会话进度（2026-07-16）

### 已做

- G01：读取原版 `com.NeatDownloadManager` 的完整 LogFile 样本，确认 4125 首连接已完成 983,040B 后，第二 Range 起点为 `983040 + (18207337 - 983040) / 2 = 9595188`；`SegmentFileFormat` 与测试已按此收紧。
- 新下载由单连接 bootstrap 开始，再递归切最大未完成区间；运行中 `applyConnectionsCount` 使用独立取消 token 收掉旧轮次，按真实 `seg.xN` 长度重规划并重发 Range。
- 修正重规划时重编号 segmentId 却不迁移文件的隐患；已有文件 ID 保持稳定，`nextId` 指向真实下一个 ID。
- 修正任务完成时旧 task snapshot 覆盖运行中连接数修改的问题。
- 产品交互追加修复：完成提示以 `Open` 为默认操作，保留 `Show in Finder` / `Close`；进度窗显示整体进度之外，还按实时 `SegmentState` 为每条 Range 连接绘制独立进度条、百分比、字节区间和状态。
- 稳定性：分析两份历史 NDM `.ips`；加 `AppDelegate` 显式保活、状态栏显式 target、非阻塞 terminate reply、Wait continuation one-shot、Progress polling 关闭、Bridge 专用队列串行化、WebSocket 长度上限与拆包 Upgrade、URLSession 主动取消、流式 merge。
- 桥：监听明确收紧到 `127.0.0.1`；自动测试真实覆盖 `waiting`/`nowaiting` 与 ShowPanel 文本帧；`ws_bridge_client.py` 支持 `--expect-flow`、`--listen-only`、`--expect`；手工清单见 `docs/BETTERNDM_SMOKE.md`。
- 修复版宿主在确认原版未占用 10007 后连续运行 3 分 36 秒未复现 SIGSEGV（超过两份历史 `.ips` 的约 2:31 / 3:16）；另一次启动经 `lsof` 验证仅监听 `127.0.0.1:10007`。
- 验收：`swift test` 当前 51 个 XCTest 全绿（NDMEngine 12、NDMCore 35、NDMBridge 4）。

### 未做 / residual gaps

- 原版 socket 1 的开放 `Range: 0-`、TLS/RTT 驱动的实时切分时刻、segment merge/rollback 启发式尚未逐事件复刻；当前是可确定、可续传、可测试的行为级对齐。
- BetterNDM 实机 Chrome smoke 尚需按清单人工操作（自动桥测试不等于 Chrome webRequest/Cookie/媒体捕获全链路）。
- exit 139 的防护已落地，但崩溃栈经过系统私有 `MenuBarClientCore` 且运行于 macOS 27 beta，不能宣称系统侧根因 100% 消失。
- MKV G07/G11、HLS G06 不在本会话 P0 交付内，维持既有 residual。

### 下一步

1. 按 `docs/BETTERNDM_SMOKE.md` 走一次真实 Chrome：Confirm on/off、Cookie、媒体面板、ShowPanel、新建任务与大文件 2→8 Apply。
2. 收集一次运行中 8→32 和 32→2 的原版/本实现并排 LogFile，比较 socket 创建、偷尾、merge/rollback 次序。
3. 若再出现 NDM `.ips`，先比较 faulting thread 是否仍为 `MenuBarClientCore → Swift MainExecutor`；若栈已变化，按新栈处理，不沿用旧结论。
