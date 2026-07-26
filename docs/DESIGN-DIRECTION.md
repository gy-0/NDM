# 视觉方向：从「冷」到「有温度」

2026-07-26 起。目标是用户提的那句话：**打印成海报都让人流连忘返**，而且「没有科技的冷漠感」。

这份文档记录的是**量出来的东西**，不是形容词。参考对象是 `/Applications/Mole.app`
（tw93，mole.fit，$9，卖得很好）。它的 GUI 不开源（GitHub 上 `tw93/Mole` 只是 Go 写的 CLI），
所以下面的结论来自对运行中窗口逐像素取样。

---

## 一、Mole 的「温度」是什么

技术栈：SwiftUI + SceneKit + Metal。资源里有真实行星纹理
（`earth.jpg` 2.4MB、`sun.jpg`、`saturn.jpg` + `saturn_ring.png`…）和一组像素小动物
（`runner-cat/dragon/fox/mole/turtle.png`）。

**但行星不是重点，我们也不做行星。** 逐像素取样后，「温度」的真正来源是两件很朴素的事：

### 1. 底色是暖的，而且是渐变的

窗口背景自上而下取样（R−B 为暖度，正值偏暖）：

| 位置 | 色值 | R−B |
|---|---|---|
| 顶部 | `#3C3318` | **+36** |
| 上部 | `#3C3522` | +26 |
| 中部 | `#302C24` | +12 |
| 底部 | `#1C1C20` | **−4** |

一层**从上到下由琥珀转中性的垂直渐变**，像窗口上方悬着一盏暖光。
卡片 `#3C3522`（+26）同属暖色系，比中段底色略亮——是"被那盏灯照到的表面"。

### 2. 数据色是冷的，衬在暖底上

CPU 柱状 `#65A382`（R−B = **−29**）。暖地面 + 冷数据 = 刻意的互补。
数据因此"跳"出来，而不是靠加饱和度硬喊。

### 3. 每个指标有自己的色相

CPU 青绿、GPU 橙、内存暖黄、磁盘红→蓝渐变、网络蓝绿。
**不是**给分类刷一堆装饰色（NDM 早就砍掉过那种"泥泞彩虹"），
而是每张图自己的量纲有自己的颜色。

### 4. 其他可搬的细节

- 大数字 + 小单位（`36` + `%`、`1,725` + `RPM`）——NDM 的 Hero 已经是这个模式，一致。
- 元信息做成小胶囊 chip（`M4 Max` / `36 GB` / `78°C`），不是灰底方块。
- 次级标签用**加宽字距的小字**（`CPU` `GPU` `内存`），这是明显的设计师手笔。
- 顶部居中的分段胶囊导航，选中项是**纯白胶囊**压在深底上，对比极高、非常笃定。

---

## 二、NDM 现状的诊断

同样取样（`docs` 里的截图流程，`NDM_QA_*` + `screencapture -l`）：

| 位置 | 色值 | R−B |
|---|---|---|
| 工具栏 | `#F9FAFD` | −4 |
| 侧边栏 | `#FBFBFD` | −2 |
| 列表 | `#FBFBFD` | −2 |
| 检查器 | `#FBFBFD` | −2 |
| 列表顶 / 中 / 底 | 三处**完全相同** | −2 |

结论两条，都在 `NDMChrome` 的令牌里：

1. **色温是冷的。** `srgb(0.982, 0.985, 0.992)`，R < G < B，偏蓝。
   深色主题更明显：`#0A0C11`，注释自己写着 "deep space blue-black"。
2. **完全没有纵向起伏。** 四处取样一模一样，是一张纯色卡纸。

这正是用户说的"冷冰冰、硬邦邦"。而且它是**前一版方向（黑曜石影院）刻意做出来的**，
不是疏忽——所以改它属于方向调整，不是修 bug。

---

## 三、代码层：它的交互是怎么写的

GUI 不开源，但 Swift 反射元数据（`__TEXT,__swift5_reflstr`）里有 2051 个字段名，
足以还原它的交互词汇。以下都是从二进制里读出来的真实属性名，不是猜的。

### 1. `celebrationMinimumBytes` —— 给愉悦设阈值

整份 dump 里最有教益的一个名字：**清理量不到某个字节数，就不播庆祝动画。**
不为琐事庆祝。一个每天用几十次的工具，如果每次都撒花，第 40 次就是冒犯。

→ NDM 直接对应：现在 3KB 的 `logger.js` 下载完，和 2GB 的电影一样放整套礼花。

### 2. `suppressPointerFocusCue` —— 焦点环只给键盘

配套还有 `headerKeyboardFocused` 与 `headerHovered` **两个独立状态**。
鼠标点出来的焦点不画环，键盘 Tab 出来的才画。

→ NDM 现在是 AppKit 默认行为，鼠标点击也会留环（本轮已在对话框里逐个手动关掉，
说明缺的是一条系统性规则而不是补丁）。

### 3. `hoverOpacity` / `inactiveOpacity` / `cleanWatchMetricHoverOpacity`

**悬停语言是透明度，不是背景色块。** 这正是用户"不要灰色方块"那条规矩的实现方式：
不给一个灰底，而是让元素自身变亮/变实。

### 4. `holdProgress` / `exitHoldActive` / `toggleHoldTasks`

危险操作用**长按 + 可见进度**代替确认弹窗。手指按住的那 0.6 秒就是确认。

### 5. `displayedBytes` vs `bytesFoundLive` / `bytesReclaimedLive`

显示值与真实值是两个变量，显示值自己插值追赶。
→ NDM 的 `SmoothProgressCenter` 已经是同一个思路，这条我们是对齐的。

### 6. `breathe` + `idleAnimationEnabled`

待机呼吸动画，而且是个**可关的设置项**——他们知道有人会嫌烦。

### 7. `animateEntrance` / `isEntering` / `incomingOpacity` / `startScale` `endScale`

每个元素都有入场，不是"啪"地出现。

### 8. `smoothedRadiansPerSecond` / `rotationVelocity` / `dragVelocity` / `settled`

速度是被平滑过的，并且有一个明确的 `settled`（停稳）状态。

### 9. `bentoRowHeight` / `cardRadius` / `poemBlockMinHeight`

便当格布局；以及——界面里有一首**诗**。"温度"有一部分根本不是视觉，是文案。

---

## 三·五、从机器码里拔出来的动效参数

字段名只能告诉你"有什么"，参数才是手感本体。以下全部由
`otool -arch arm64 -tV` 反汇编、回溯 `mov`/`movk` 链重建 64 位双精度位模式解出，
不是猜的。（复现脚本见本节末。）

| API | 调用点数 | 实际取值 |
|---|---|---|
| `easeOut(duration:)` | **48** | 0.08 / 0.10 / 0.12 / 0.16 / 0.18 / 0.20 / 0.25 / 0.28 / 0.39 / 1.2 |
| `spring(response:dampingFraction:blendDuration:)` | 13 | response **0.28–0.53**，damping **0.78–0.86**（个别 1.2） |
| `easeInOut(duration:)` | 3 | 0.26 / 0.5 / 0.875 |
| `linear(duration:)` | 2 | 0.12 / 1.0 |
| `delay(_:)` | 2 | 0.20 / 1.2 |

它只用 `spring` 的 `(response:dampingFraction:blendDuration:)` 这一个重载，
`blendDuration` 恒为 0。

### 三条结论

1. **家常曲线是 `easeOut`。** 48 : 3 : 2 碾压 easeInOut 与 linear。
   东西是"减速着落位"，不是"匀速滑过来"。
2. **时长极短。** 绝大多数落在 **0.08–0.25 秒**，只有一处 1.2s。
3. **damping 0.78–0.86** —— 只过冲一次、幅度很小。要完全不弹的地方用 1.2（过阻尼）。

### 对照 NDM

`QuietFinderRowView.celebrateCompletion()` 用的是 `CASpringAnimation`
（stiffness 320、damping 14、mass 1）。换算成 SwiftUI 的单位：

```
response        = 2π/√(k/m) = 0.351   ← 在 Mole 的 0.28–0.53 区间内 ✓
dampingFraction = c/(2√(km)) = 0.391  ← Mole 是 0.78–0.86，NDM 松了一倍
```

**这就是"弹一下"的数学解释。** NDM 的回弹阻尼只有 Mole 的一半，
所以它过冲更大、来回更多次。

现有时长对照：落位 morph 0.46s（比 Mole 任何东西都慢，除它那一处 1.2s）、
海报溶解 0.28s、栏位淡入 0.18s、对话框入场 0.16s、中止淡出 0.083s ——
除落位外都在区间内。

### 复现方法

```bash
otool -arch arm64 -tV /Applications/Mole.app/Contents/MacOS/Mole > mole.asm
# 找到 bl 到 AnimationV6spring / AnimationV7easeOut8duration 的调用点，
# 从 `fmov dN, xM` 往回回溯最近一段 mov/movk 链，
# 拼成 64 位后 struct.unpack('<d', ...) 解回 Double。
```

注意二进制是 fat 的（x86_64 + arm64），不指定 `-arch arm64` 会拔到错的那一半。
另外少数值解出来是 1/1024 量化的（0.1953、0.5312…），是回溯漏了一段 movk，
真值大概率是 0.2、0.53。

---

## 四、要做的改动

按"值得做且能被看见"排序。每项都必须过 `./Scripts/check.sh` 四道闸门。

- [x] ~~A. 庆祝阈值~~ —— **用户否决**：「我真的觉得我现在各种文件都庆祝没啥问题」。已撤销。
- [x] **A′. 阻尼对齐**（对应三·五）。三处弹簧统一到 `NDMChrome.spring`，response 0.34 / damping 0.80。
- [x] **B. 焦点环只给键盘**（对应 2）。`FocusRingPolicy` + `adoptFocusRingPolicy`，7 个文件采用。
- [x] **C. 悬停不再用灰底**（对应 3）。全部 hover/pressed 改为 accent 色调（`NDMChrome.accentWash`），六处灰色洗块清零。
- [ ] **D. 入场动效**（对应 7）。行/卡片有入场，而不是突然出现。
- [ ] **E. 文案的温度**（对应 9）。空状态、完成、失败几处的措辞。

**不做**：长按代替确认（NDM 刚建立 `NDMDialog`，两套确认语言会打架）；
呼吸动画（先做完上面几条再看）。

---

## 五、关于配色的一条更正

第一版这份文档里我写了"把 Mole 的暖色渐变搬到 NDM"。**那是错的读法**，用户明确否掉：
Mole 只是"简洁又美丽"的一个例子，不是要抄它的主题。

取样数据本身仍然有效（NDM 现在四处取样完全相同、且偏蓝，确实平且冷），
但那是 NDM 自己要不要有起伏的问题，跟"变成琥珀色"无关。留待单独判断。

## 六、进度

- [x] Mole 逐像素取样
- [x] Mole 二进制反射元数据分析（真正有用的一层）
- [x] 组件库调研（结论：不引，见第四节"不做"）
- [x] A 庆祝阈值 —— 用户否决，已撤销
- [x] 动效参数逆向（三·五节）
- [x] A′ 阻尼对齐
- [x] B 焦点环只给键盘
- [x] C 悬停不再用灰底
- [ ] D 入场动效
- [ ] E 文案温度
- [ ] awesome-mac 下载器功能清单（`jaywcjlove/awesome-mac` 的 Download 段落抓取失败，需换源重试）
