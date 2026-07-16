# NDM 工程

基于 **Neat Download Manager 1.3** 的完整逆向 → clean-room Swift 开源重写。

## 状态：**宿主主线对等完成（M0–M6）**

| 阶段 | 状态 |
|------|------|
| 宿主逆向规格 | ✅ `reverse/specs/00`–`14` |
| Ghidra 全量反编译 | ✅ 2147 函数 → `reverse/dumps/full_decompile/` |
| AES / segments / WS 协议 | ✅ 已对照二进制验证并落到 Swift |
| Swift 宿主 | ✅ HTTP/FTP/HLS/NTLM/MKV/代理/桥/Wait/ShowPanel/续传/UI |
| Chrome 扩展 | **BetterNDM**（不逆向原版） |

功能勾选见 [`docs/FEATURE_PARITY.md`](docs/FEATURE_PARITY.md)。

### 验证

```bash
cd ~/NDM/reverse/tools && python3 test_re_specs.py
cd ~/NDM && swift test
swift run NDM   # 启动宿主（WS :10007，可接 BetterNDM）
```

### BetterNDM 联调

1. `swift run NDM`
2. Chrome → 加载 unpacked：`reverse/extension/BetterNDM/`
3. 菜单 **Browsers** 可打开引导；设置里可开关 ShowPanel / Wait 确认窗

### 目录

```
reverse/          # 规格、dumps、fixtures、BetterNDM
Sources/          # Swift clean-room：NDMCore / NDMEngine / NDMBridge / NDMApp
Tests/
NeatDownloadManager.app   # 原版参考（勿当源码）
```

## 关键结论（一句话）

原版宿主 = **AppKit UI** + **C++ 自研多连接引擎** + **SQLite** + **WS `127.0.0.1:10007` / `neatextension.v1`**；  
我们对照规格与 Ghidra 伪代码重写等价逻辑，扩展侧复用 BetterNDM。
