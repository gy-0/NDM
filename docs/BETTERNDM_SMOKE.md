# BetterNDM ↔ Swift 宿主手工 smoke

## 准备

1. 确认没有其他程序占用 `127.0.0.1:10007`。
2. 在本仓库根目录运行：`swift run NDM`
3. Chrome → 扩展管理 → 开发者模式 → 加载未打包扩展 → 选择 `extension/BetterNDM/`

另：若要用 Python 探针，需 `python3 -m pip install websockets`，探针脚本可自备（连同一 endpoint）。

## 检查项

1. 点击普通 ZIP/DMG 下载链接，宿主应出现 Wait / 任务。
2. 打开包含 `.dat`、`.bin`、XHR 或隐藏 iframe 资源的网页，不能自动创建 NDM 下载任务。
3. 直接打开 MP4 或带 `Content-Disposition: attachment` 的顶层链接，仍应交给 NDM。
4. 在 X/Twitter 时间线找到视频帖子：操作栏应出现 **NDM**；点击后宿主应读取该帖页面、显示清晰度选择，而不是下载 HTML 或任意 TS 分片。
5. 打开 YouTube `/watch?v=...`：点赞/分享一行应出现 **使用 NDM 下载**；点击后应显示包括 1080p/4K（源站实际提供时）在内的解析结果。
6. 打开 B 站 `/video/BV...`：点赞/投币/收藏/分享一行应出现 **NDM 下载**；点击后应把去掉跟踪参数的 BV/av 页面 URL 交给宿主解析。
7. 打开 TikTok `/@user/video/id`：分享等操作所在区域应出现 **使用 NDM 下载**，并把去掉查询参数的规范视频页 URL 交给宿主解析。
8. 在包含内嵌 PDF、Office 文档、EPUB 或 ZIP 的网页中，右下角应出现“NDM · N 项资源”；展开后应显示文件名、格式、大小（响应提供时）和来源域名，未点击“下载”前宿主不能新增任务。
9. 同一 PDF 的多个 `range`/签名 URL 只显示一项；JS、JSON、图片、DAT/BIN 和 TS 分片不能出现在资源架。
10. 资源架收起后仍保留计数入口；BetterNDM 工具栏徽标显示当前页检测数量，点击可重新展开资源架及当前最近的视频入口。
11. X/Twitter 的旧浮动候选默认只突出“推荐 · 选择画质并下载”，原始格式收进“其他格式”；页面解析入口存在时，所有裸 TS 响应都不展示。
12. 鼠标离开媒体约 2 秒后，通用媒体浮标应完整隐藏，不再遮挡播放；移回媒体会短暂出现，点击 BetterNDM 工具栏图标则恢复并展开当前最近的媒体面板。
13. 打开会由隐藏资源触发 DAT/BIN 下载的页面：Chrome 下载列表里也不应残留该垃圾下载；手动顶层打开同一 URL 不应被取消。
14. 右键 BetterNDM 工具栏图标，关闭 **Catch browser downloads** 后，徽标显示 `Off`；再次开启后恢复。
15. Wait 窗 Download / Cancel 后，扩展侧 waiting 状态应解除。
16. 设置里开关媒体面板时，扩展应同时识别 `ShowPanelChrome` 和兼容的 `ShowPanelEdge` 消息。
17. 桥地址可在宿主「浏览器」窗复制：`ws://127.0.0.1:10007/download`

## 协议摘要

- WebSocket path `/download`，subprotocol `neatextension.v1`
- `6:media-page` 表示由站点按钮发送的规范页面地址，宿主必须进入 yt-dlp 预检/清晰度选择，不能按普通文件下载。
- 扩展内部 opcode `19` 只把发现的文档/压缩包/电子书/安装包加入资源架；直到用户点击资源行，才使用既有 opcode `6` 发送 `6:normal` 下载请求。
- 文本帧 CRLF 字段（详见 `Sources/NDMCore/Bridge/BridgeProtocol.swift`）
