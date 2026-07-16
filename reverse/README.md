# NDM 完整逆向工程（Reverse Engineering）

> **阶段目标：先完整逆向，再谈 Swift 重写。**  
> 参考样本：`NeatDownloadManager.app` v1.3 (build 24) · universal · 2021  
> 作者源码路径痕迹：`/Users/kia/Desktop/NeatForMac-1.3.24/`

## 为什么先逆向、后重写

原版已发布多年、行为成熟。从零“凭感觉写”容易在边界情况、续传、代理、分段合并等处留下漏洞和不稳定。  
**先把宿主（下载引擎 + UI + 存储 + WS 服务端）规格抠干净，再 clean-room 实现**，扩展则直接站在社区成熟成果上。

## 当前阶段策略

| 做 | 不做（现在） |
|----|----------------|
| 主程序（`.app`）静态/运行时规格 | 功能迁移到 Swift |
| 协议 / 数据格式 / 引擎 / UI 类表 | 从零发明扩展协议 |
| 文档化到可实现程度 | 再逆向原版 Chrome 扩展 |

### Chrome 扩展：已定论

- **采用 BetterNDM**（`reverse/extension/BetterNDM/`，MIT，社区 fork + 更好 UI）
- **不再**投入逆向原版 Chrome Web Store 扩展
- 我们只保证 **宿主 WS 服务端** 与 BetterNDM/原版协议兼容

仓库里若存在 `Sources/` Swift 骨架，**视为提前试写，可忽略**；正式实现以本目录规格为准。

## 文档索引

| 文档 | 内容 |
|------|------|
| [specs/00_OVERVIEW.md](specs/00_OVERVIEW.md) | 总览、技术栈、架构图 |
| [specs/01_SOURCE_LAYOUT.md](specs/01_SOURCE_LAYOUT.md) | 原版源码树推断 |
| [specs/02_OBJC_CLASSES.md](specs/02_OBJC_CLASSES.md) | ObjC 类 / 方法 / ivar |
| [specs/03_ENGINE.md](specs/03_ENGINE.md) | C++ 下载引擎 |
| [specs/04_SEGMENTS_FORMAT.md](specs/04_SEGMENTS_FORMAT.md) | `segments.bin` / `seg.xN` |
| [specs/05_DATABASE.md](specs/05_DATABASE.md) | SQLite 与任务目录 |
| [specs/06_SETTINGS.md](specs/06_SETTINGS.md) | UserDefaults / 代理 / AES |
| [specs/07_BROWSER_PROTOCOL.md](specs/07_BROWSER_PROTOCOL.md) | WebSocket + 扩展 |
| [specs/08_UI.md](specs/08_UI.md) | 窗口与交互 |
| [specs/09_STATE_MACHINES.md](specs/09_STATE_MACHINES.md) | HTTP/FTP 状态机 |
| [specs/10_GAPS.md](specs/10_GAPS.md) | 尚未钉死的点 / 后续动态分析 |
| [specs/11_APP_LIFECYCLE.md](specs/11_APP_LIFECYCLE.md) | AppDelegate 编排 + 引擎状态（含 Merging） |
| [specs/12_MODULE_BOUNDARIES.md](specs/12_MODULE_BOUNDARIES.md) | 重写用模块边界与 DTO |
| [specs/13_CRYPTO_AES.md](specs/13_CRYPTO_AES.md) | **r2 还原** 偏好 AES（密钥 SG2921） |

## 原始转储（dumps）

```
reverse/
├── bin/                 # arm64 切片
├── dumps/               # strings / otool / class dump
├── fixtures/            # 可提交的运行时证据快照（schema、segments）
├── tools/
│   ├── parse_segments.py
│   ├── protocol_message.py
│   └── test_re_specs.py # 驱动真实工具的单元/结构测试
├── extension/
│   ├── BetterNDM/       # ★ Chrome 扩展主线（社区 MIT）
│   └── …                # 原版/clean 仅考古
├── specs/               # 人工整理规格 00–12
└── README.md
```

### 跑规格测试

```bash
cd ~/NDM/reverse/tools && python3 test_re_specs.py
```

### 全量反编译（Ghidra）

```
reverse/dumps/full_decompile/
├── README.md
├── ENGINE_FUN_MAP.md
├── ghidra_c/           # 2147 个函数的伪 C（~9.4MB）
│   ├── INDEX.tsv
│   └── SUMMARY.txt     # total=2147 ok=2147
└── asm_all/            # TEXT 段反汇编大文件
```

用 **Ghidra 12** headless 从 arm64 切片导出；**不是**作者原工程源码（C++ 符号已 strip，大量名为 `FUN_*`）。


## 证据来源

1. Mach-O 符号 / ObjC metadata / 类型编码（**主程序**）  
2. 字符串与日志格式（`LogFile.txt`）  
3. 运行时 Application Support + SQLite + segments.bin  
4. Chrome 扩展：**BetterNDM**（协议兼容性交叉验证）  
5. Preferences plist  

## 完成度（自评）

| 子系统 | 完成度 | 说明 |
|--------|--------|------|
| 整体架构 | 95% | 模块边界清晰 |
| ObjC UI 层 | 90% | 类/方法/ivar 已表列 |
| Chrome 扩展 | ✅ 外包 | **BetterNDM**，不再逆向原版 |
| WS 服务端协议 | 90% | 文本字段表已还原；与 BetterNDM 兼容 |
| SQLite 模型 | 95% | schema + 枚举值已验证 |
| segments.bin | 90% | 24B 记录 + segmentId↔seg.xN 已证实；合并稀疏 id 已见 |
| 引擎状态机 | 90% | Unknown→…→Merging→Completed 日志闭环 |
| 引擎分段策略 | 70% | 流程清晰，触发阈值待动态分析 |
| App 编排 | 90% | AppDelegate 生命周期已文档化 |
| AES 密钥 | **100%** | r2 还原 `SG2921` + CBC/IV0；fixture 密文验证 |
| NTLM/Digest 细节 | 40% | 仅知支持，未逐字节还原 |
| MKV/WebM 合流 | 50% | 模块存在，算法未深入 |

**“完整逆向”的可交付定义**：实现者无需再打开二进制，仅凭 `specs/` 即可写出功能等价实现。  
当前主路径已覆盖；`10_GAPS.md` 中项需要动态调试补齐后再冻结 v1 规格。
