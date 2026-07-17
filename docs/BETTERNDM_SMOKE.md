# BetterNDM ↔ Swift 宿主手工 smoke

## 准备

1. 确认没有其他程序占用 `127.0.0.1:10007`。
2. 在本仓库根目录运行：`swift run NDM`
3. Chrome → 扩展管理 → 开发者模式 → 加载未打包扩展 → 选择 `extension/BetterNDM/`

另：若要用 Python 探针，需 `python3 -m pip install websockets`，探针脚本可自备（连同一 endpoint）。

## 检查项

1. 从网页触发下载，宿主应出现 Wait / 任务。  
2. Wait 窗 Download / Cancel 后，扩展侧 waiting 状态应解除。  
3. 设置里开关媒体面板时，扩展应收到 ShowPanel 类消息。  
4. 桥地址可在宿主「浏览器」窗复制：`ws://127.0.0.1:10007/download`

## 协议摘要

- WebSocket path `/download`，subprotocol `neatextension.v1`
- 文本帧 CRLF 字段（详见 `Sources/NDMCore/Bridge/BridgeProtocol.swift`）
