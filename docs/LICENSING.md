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
| 触发位置 | 设置保存 + 进度窗 Apply | — |

后续开关点（批量、Smart Finalize 扩展、站点规则）加在 `LicenseStore` 常量旁。
升级页：`UpgradeWindowController`（触发式弹出，不做开屏骚扰）。购买链接占位 `ndm.example.com/pro`，上线前替换。
