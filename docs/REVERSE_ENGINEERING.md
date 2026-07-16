# Neat Download Manager 1.3 — 逆向分析

参考二进制：`NeatDownloadManager.app`（v1.3 build 24，universal x86_64+arm64）

> 本仓库采用 **功能等价的 clean-room 重写**，不反编译、不粘贴原版机器码/反汇编为源码。  
> 分析仅用于：模块边界、协议行为、数据模型、交互流程的规格提取。

## 1. 技术栈（原版）

| 层 | 技术 |
|----|------|
| UI | AppKit + NIB（`NSWindowController` 家族） |
| 核心引擎 | C++ / Objective-C++（路径痕迹：`NeatEngine/NeatDownloadEngine.mm`） |
| 网络 I/O | 自研 socket + `kqueue`（`NeatKQueue` / `NeatKqSocket`） |
| 持久化 | SQLite3（`libsqlite3`） |
| 浏览器桥 | 本地 WebSocket Server + Safari Web Extension + MV2 扩展脚本 |
| 进程形态 | `LSUIElement=true`（菜单栏/后台应用，无 Dock 图标） |

依赖框架：Foundation、AppKit、ApplicationServices、CoreFoundation、CoreServices、IOKit、Security、libsqlite3、libc++。

## 2. 架构总览

```
┌─────────────────────────────────────────────────────────┐
│  Browser Extension (bg.js / ct.js / Safari appex)       │
│  webRequest 拦截 · 视频探测 · 右键菜单 · 浮动按钮        │
└──────────────────────────┬──────────────────────────────┘
                           │ WebSocket → 127.0.0.1
┌──────────────────────────▼──────────────────────────────┐
│  AppKit UI                                              │
│  Main / URL / Download / Settings / Auth / Browsers …   │
│  Status Item · Drag & Drop                              │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  NeatDownloadEngine (C++)                               │
│  Request · Auth · Proxy · Bandwidth · SegmentManager    │
│  SocketHttp / Ftp / HlsMaster · File merge              │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  SQLite: downloads · auths · headers                    │
│  每任务目录: segments.bin · 分段临时文件                 │
└─────────────────────────────────────────────────────────┘
```

## 3. 核心 C++ / ObjC 符号（模块映射）

### 3.1 下载引擎

| 符号 | 职责 |
|------|------|
| `NeatDownloadEngine` | 单任务引擎：建连、调度、状态机、线程 |
| `NeatDownloadRequest` | URL / method / headers / post / UA / page 元数据 |
| `NeatSegment` / `NeatSegmentManager` | 动态分段、续传、合并、`segments.bin` |
| `NeatBandWidth` | 运行时限速 |
| `NeatEngineSocket` | 引擎侧连接抽象 |
| `NeatSocketHttp` | HTTP(S) Range 下载 |
| `NeatSocketFtp` / `NeatSocketFtpData` | FTP 控制/数据通道 |
| `NeatSocketHlsMaster` | HLS / m3u8 → TS 分段拉取与合并 |
| `NeatAuth` / Basic / Digest / NTLM | HTTP 与代理认证 |
| `NeatUrl` / `NeatPunyCode` | URL 解析与国际化域名 |
| `NeatKQueue` / `NeatKqSocket` | 事件驱动 I/O |
| `NeatFile` / `NeatFileUnix` | 文件写入 |
| `NeatWebSocketServer` / `NeatWebSocket` / Listener | 扩展通信 |
| `NeatMKV` / `NeatMKVMuxer` / `NeatWebmReader` | 音视频合流（自适应流） |
| `NeatDB` / `NeatDBHelper` | SQLite 访问 |
| `NeatCriticalSection` / `NeatEvent` / `NeatThread` | 同步原语 |

### 3.2 UI（Window Controllers / Views）

| 类 | 窗口 |
|----|------|
| Main（`NeatMainWindow` nib） | 任务列表：Complete / Incomplete / 类型分类 |
| `NeatUrlWindow` | 新建 URL |
| `NeatDownloadWindow` / `MKV` | 单任务进度、分段条、连接数、限速 |
| `NeatSettingWindow` | 目录、UA、代理、并发策略、开机启动等 |
| `NeatAuthWindow` | 认证凭据 |
| `NeatBrowsersWindow` | 浏览器扩展引导 |
| `NeatPropertiesWindow` | 任务属性 |
| `NeatCompleteWindow` / `NeatErrorWindow` / `NeatQuitWindow` / `NeatWaitWindow` / `NeatAboutWindow` | 完成/错误/退出/等待/关于 |
| `NeatProgressBar` / `NeatSegmentsProgressBar` | 总进度 + 分段热力条 |
| `NeatStatusItemView` | 菜单栏图标 |
| `NeatCustomButton` / `NeatTextField` / `NeatTableView` | 自定义控件 |

## 4. 数据模型（SQLite）

模板库：`Resources/NeatDB.db`  
运行时：`~/Library/Application Support/com.NeatDownloadManager/`

```sql
downloads (
  id, url, method, filename, ltype, filesize, category, status,
  bandwidthlimit, connections, lasttry, firsttry, useragent,
  resumable, pageurl, pagetitle, hittitle, mimetype, errortext,
  urla, postdata, folderpath
)
auths (id, target, protocol, user, pass)
headers (id, header)  -- 关联 downloads.id
```

任务工作目录按数字 id 分文件夹，内含分段状态（`segments.bin` 等）。

## 5. 浏览器扩展协议

- **Manifest V2** 扩展：`bg.js`（webRequest + contextMenus）+ `ct.js`（页面注入、视频按钮）
- Safari：`com.apple.Safari.web-extension` appex，同套资源
- 与宿主通过 **WebSocket 连本地服务**（字符串含 `127.0.0.1`、`Waiting for new URL from Browser Extension`）
- 消息形态为数组 opcode（ct.js 中可见 `1,2,3,4,5,6,7,9,13` 等）
- 能力：捕获下载链接、Cookie、POST body、m3u8/mp4、YouTube/Vimeo/Facebook 等站点特化、音视频分轨 → MKV 提示

## 6. 功能清单（规格来源）

见 [FEATURE_PARITY.md](./FEATURE_PARITY.md)。

## 7. 原版限制（重写时可改进，但 v1 先对齐）

- UI 为 2021 年代 AppKit NIB，非 SwiftUI
- 扩展仍是 MV2 思路
- Win/Mac 版本号在官网上不一致
- 闭源，无公开协议文档 → 协议需通过抓包/行为测试对齐

## 8. 重写策略

1. **规格驱动**：行为测试 + 功能清单，而非二进制还原  
2. **语言**：Swift 5.9+（UI AppKit 或 SwiftUI；引擎 Swift/NIO 或纯 URLSession+自定义分段）  
3. **模块边界对齐原版**，便于对照验收  
4. **Bundle ID / 数据路径可配置**，避免与已装 NDM 冲突  
5. 产品名待定；工程代号暂用 `NDM` / 模块前缀 `NDM`
