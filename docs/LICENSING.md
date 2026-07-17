# License 密钥体系

离线校验的 Ed25519 签名密钥，格式：

```
NDMP1.<base64url(payload JSON)>.<base64url(signature)>
payload = {"email":"buyer@example.com","exp":"2027-07-16"}   # exp 可省略 = 永久
```

- 公钥内嵌在 `Sources/NDMCore/License/LicenseStore.swift`（`productionPublicKeyBase64`）。
- **私钥在 `~/.ndm-license/signing-key.txt`，绝不入库。**换钥匙时同步更新公钥常量。
- `exp` 只作为"含一年更新"的凭据边界；到期后老版本继续可用（激活时校验，不做运行时反激活）。

## 签发一把钥匙

```bash
swift Scripts/make-license.swift buyer@example.com 2027-07-16   # 或省略日期=永久
```

## 功能开关（当前生效）

| 开关点 | Free | Pro |
|---|---|---|
| 每任务连接数上限 | 4 | 32 |
| 单视频画质 | 最高 1080p | 4K / 8K |
| 播放列表 / 合集 | 当前视频 | 整合集顺序队列 |
| 字幕交付 | — | 同名字幕与语言后缀 |
| 触发位置 | 用户实际选择 32 连接、4K、整合集或字幕时 | 激活后自动继续原操作 |

升级页：`UpgradeWindowController`（触发式弹出，不做开屏骚扰）。媒体边界统一由
`ProAccessPolicy` 判断，升级页会解释用户刚刚选择的具体价值，而不是固定展示一张功能表。

购买地址不再写死在源码中。打发行包时提供真实 HTTPS 结账地址：

```bash
NDM_PURCHASE_URL="https://store.example.com/checkout" Scripts/package-app.sh
```

脚本会把它写入签名 App 的 `NDMPurchaseURL`。未配置时购买按钮会明确显示“购买通道即将开放”，
不会打开占位域名；许可证激活仍然可用。
