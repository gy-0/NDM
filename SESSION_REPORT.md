# 本会话交付报告（2026-07-17，继续打磨）

## 做了什么

- 删除：可选「仅移除任务」或「移入废纸篓」
- 主菜单：Start / Pause / Progress / Properties / Copy URL / ⌘⌫ Remove
- 菜单栏：活跃数 + 速度摘要；Settings 强引用防闪退
- Properties / Wait：去掉 raw enum，补友好文案与 Escape
- 空状态：副文案 + ⌘N / 拖放提示
- Inspector：Copy URL、Remove
- Progress：Close（活跃时先 Pause）
- Browsers / About：桥状态、复制地址、产品化文案

## 验收

```bash
cd /Users/gaoyuan/NDM
swift test   # 57 通过
swift run NDM
```

## 仍待

- NDM Relay Chrome 实机 smoke
- 长时稳定性观察
- MKV / HLS 边缘行为
