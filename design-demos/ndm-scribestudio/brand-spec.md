# NDM × ScribeStudio · Brand Spec

> 采集日期：2026-07-21
> 资产来源：本地产品仓库与聚焦后的当前运行窗口
> 资产完整度：产品 UI 完整；NDM 独立主 App 图标仍沿用历史自有资产，后续可单独重做

## 核心资产

### NDM

- 当前标识：`assets/ndm-icon.png`（128 × 128，源自 NDM Relay 自有扩展资产）
- 当前 UI：`assets/current-ndm.png`（聚焦窗口截图，2048 × 1368）
- 签名功能：多连接下载、状态/类型筛选、来源与大小可扫读、失败后更新链接、完成后分享或交给 ScribeStudio
- 禁止：把绿色 N 图标重画成通用蓝紫下载箭头；把“快”表现成虚构倍速或霓虹速度表

### ScribeStudio

- 当前标识：`assets/scribestudio-icon.png`（真实本地 App 图标）
- 当前 UI：`assets/current-scribestudio.png`（聚焦窗口截图，2240 × 1520）
- 签名功能：媒体审片、识别配方、字幕跟随、逐段校对、多格式交付、接收 NDM 下载成果
- 禁止：紫色 AI 渐变、脑袋/星光类 AI 图标、假模型榜单、把 API 凭据放成视觉主角

## 共享设计原则

- 两款产品是一条“取得内容 → 理解内容 → 交付内容”的连续工作流。
- 家族识别来自一致的 4/8/12/16/24 间距节奏、同一套 SF/PingFang 字体、发丝分割线、单强调色与清晰操作主次。
- NDM 偏速度与掌控，ScribeStudio 偏专注与阅读；两者不强求相同色面比例。
- 每屏最多一个主强调色。绿色只在成功或方向本身选择绿色时出现，不把所有控件都染成品牌色。

## 色板基线

- Canvas Light：`#F4F4F1`
- Surface：`#FCFCFA`
- Ink：`#191B19`
- Muted：`#686D68`
- Hairline：`#D9DAD5`
- Dark Stage：`#101311`
- Scribe existing green：`#1F675F`
- NDM existing teal runtime accent：约 `#158A80`
- Signal red/orange candidate：`#E9573F`

## 字型

- UI/正文：`-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif`
- 数据/时码：`"SF Mono", ui-monospace, monospace`
- 原型中不联网加载字体，确保双击即可稳定打开。

## 素材质量记录

- NDM 当前 UI 截图：9/10。当前真实版本、焦点明确、分辨率高；含真实本机任务名，不在对外营销中使用。
- ScribeStudio 当前 UI 截图：9/10。直接由当前仓库 Electron 进程渲染、焦点明确；空状态适合审查结构。
- 两款 App 图标：ScribeStudio 8/10；NDM 历史标识 5/10，但它是当前唯一真实身份资产，按协议保留而不伪造替代。

## 气质关键词

- 原生
- 精确
- 有掌控感
- 克制但不寡淡
- 工具矩阵

