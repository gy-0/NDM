# BetterNDM ↔ Swift 宿主手工 smoke

目标：验证 BetterNDM 只连接 clean-room Swift 宿主，覆盖 `waiting` / `nowaiting`、Cookie、媒体面板 `ShowPanel` 与任务落库。宿主数据仍写入 `~/Library/Application Support/dev.ndm.open`。

## 前置检查

```bash
cd /Users/gaoyuan/NDM
lsof -nP -iTCP:10007 -sTCP:LISTEN
```

若输出是原版 `NeatDownloadManager`，先退出原版；不要同时启动两个宿主。确认端口空闲后再运行 `swift run NDM`。Python 客户端另需 `python3 -m pip install websockets`。

## 8 步验收

1. 在 Chrome 的扩展管理页打开“开发者模式”，加载 `reverse/extension/BetterNDM/`；保持原版 Neat 完全退出。
2. 启动 `swift run NDM`，确认没有端口占用提示；数据目录应为 `dev.ndm.open`，不是原版目录。
3. 在 NDM Settings 打开 “Confirm browser downloads”，执行：
   `python3 reverse/tools/ws_bridge_client.py --expect-flow --url https://example.com/file.bin`。应先收到 `waiting`；在 Wait 窗点 Download 或 Cancel 后应收到 `nowaiting`，红色关闭按钮也应等价 Cancel。
4. 关闭 “Confirm browser downloads” 后重复上一步。仍应看到成对的 `waiting` / `nowaiting`，但不弹 Wait 窗；任务应立即出现在主窗口。
5. 在 Settings 切换 “Show browser media panel”。用
   `python3 reverse/tools/ws_bridge_client.py --listen-only --expect ShowPanelChrome=1`
   或 `ShowPanelChrome=0` 监听，再切一次设置；应收到对应值。新连接建立时也应收到当前 ShowPanel 状态。
6. 在 Chrome 页面右键一个直链，选择 BetterNDM 下载。确认任务 URL、文件名、Referer/页面标题合理；需要 Cookie 的测试页应能开始下载，而不是返回未登录页面。
7. 打开包含 MP4/m3u8 的页面，确认 BetterNDM 页面媒体面板随 ShowPanel 开关显示/隐藏；选择媒体项后宿主任务的类型为 `media` 或 `hls`。若含 `urla` 双轨，确认任务进入媒体合并路径。
8. 下载一个足够慢的大文件，在 Progress 窗把 Connections 由 2 改为 4/8。`LogFile.txt` 应出现 `cancelling active Range round for live replan` 和 `Replanned active transfers`，下载最终字节应正确；最后暂停/继续一次确认续传。

## 仅桥协议的自动验收

`swift test --filter BrowserBridgeIntegrationTests` 使用临时端口，不会碰 `10007`，覆盖：

- WebSocket `/download` + `neatextension.v1`；
- `waiting` → 任务落库 → `nowaiting`；
- ShowPanel 文本帧真实收发；
- 并发 broadcast/stop 的串行化防护。

