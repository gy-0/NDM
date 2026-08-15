# Amicro → NDM 全量采用矩阵

审计基线：`Subhan-code/Amicro--Micro-transitions-` commit `9890c9d64cd6d52a6ad02b6a4695fd8eb438afbc`。

- Registry JSON：**164**（采用 18 / 改造 35 / 不适用 111）
- 全仓扫描：260 个 TS/TSX；156 个 registry UI、5 hooks、2 libs、1 manifest。
- 156 个 UI 中 134 个是持续循环动画，且没有组件主动接入 Reduce Motion；因此“不适用”不是漏看，而是避免同质 spinner、假进度和桌面端动效噪音。
- 原则：AppKit/Core Animation 承担交互、键盘、主题和无障碍；WebKit 仅保留局部 Appllama visual glyph。
- License：Amicro MIT，版权 `Copyright (c) 2026 SYED SUBHAN UDDIN`；实质性移植需保留许可。

## 决策定义

- **采用**：已接入 NDM 真实状态路径，并至少通过构建；关键项已有运行截图/AX 证据。
- **改造**：模式有价值，但必须折叠进共享原生 primitive、改用真实状态或去除 Web/品牌语义。
- **不适用**：同质无限 loader、假进度、Web cursor/scroll gimmick，或 AppKit 已有更合适原生控件。

## 164 项逐条矩阵

| # | 组件 | Registry 源路径 | 决策 | NDM 落点 | 原因 / 原生移植方式 |
|---:|---|---|---|---|---|
| 1 | `use-mouse-position` | `/tmp/amicro/registry/hooks/use-mouse-position.json` | **采用** | Paste Anything / Gallery | NSTrackingArea 原生指针位置，驱动 magnetic/glow/spotlight |
| 2 | `use-reduced-motion` | `/tmp/amicro/registry/hooks/use-reduced-motion.json` | **采用** | 全部 AmicroMotion 与现有循环动画 | NSWorkspace Reduce Motion 门控 |
| 3 | `use-scroll-progress` | `/tmp/amicro/registry/hooks/use-scroll-progress.json` | **不适用** | — | NDM 是固定桌面工作区，不以页面滚动驱动核心状态 |
| 4 | `use-stagger` | `/tmp/amicro/registry/hooks/use-stagger.json` | **采用** | 空状态、Smart Delivery 成果列表 | 40–55ms 原生 stagger |
| 5 | `use-web-haptics` | `/tmp/amicro/registry/hooks/use-web-haptics.json` | **不适用** | — | Web Haptics 不适用于 AppKit；用 VoiceOver/系统反馈 |
| 6 | `presets` | `/tmp/amicro/registry/lib/presets.json` | **采用** | AmicroMotion spring primitives | 提取 spring 参数，不引入 motion/react |
| 7 | `utils` | `/tmp/amicro/registry/lib/utils.json` | **改造** | AmicroMotion 内部工具 | 仅取 clamp/compose 思路；Swift 原生实现 |
| 8 | `amicro` | `/tmp/amicro/registry/registry.json` | **不适用** | 构建清单 | registry manifest，不是视觉组件 |
| 9 | `accordion-loader` | `/tmp/amicro/registry/ui/accordion-loader.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 10 | `app-icon-load` | `/tmp/amicro/registry/ui/app-icon-load.json` | **采用** | NowDownloadingHero 通用文件 glyph | 真实 progressFraction 确定进度环 |
| 11 | `apple-breathe` | `/tmp/amicro/registry/ui/apple-breathe.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 12 | `apple-equalizer` | `/tmp/amicro/registry/ui/apple-equalizer.json` | **改造** | 音频提取 running | 需绑定真实 extraction state，停止后 IconSwap |
| 13 | `apple-icon-morph` | `/tmp/amicro/registry/ui/apple-icon-morph.json` | **采用** | 进度窗 preparing/finalizing 与 pause/resume | 原生 SF Symbol blur/scale morph |
| 14 | `apple-pulse-dots` | `/tmp/amicro/registry/ui/apple-pulse-dots.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 15 | `apple-scale-pulse` | `/tmp/amicro/registry/ui/apple-scale-pulse.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 16 | `apple-sound-wave` | `/tmp/amicro/registry/ui/apple-sound-wave.json` | **改造** | 音频提取 running | 需绑定真实 extraction state，禁空闲循环 |
| 17 | `apple-text-reveal` | `/tmp/amicro/registry/ui/apple-text-reveal.json` | **改造** | 空状态标题 | 折叠到 WordReveal，移除 Apple branding |
| 18 | `apple-unlock` | `/tmp/amicro/registry/ui/apple-unlock.json` | **采用** | Smart Delivery 完成 hero | 一次性成功揭示，不循环 |
| 19 | `arc-tracer` | `/tmp/amicro/registry/ui/arc-tracer.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 20 | `bar-cascade` | `/tmp/amicro/registry/ui/bar-cascade.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 21 | `bar-sweep` | `/tmp/amicro/registry/ui/bar-sweep.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 22 | `blur-text` | `/tmp/amicro/registry/ui/blur-text.json` | **改造** | 状态标题短切换 | 只保留 4px→0 blur 语义，已由 TextMorph 覆盖 |
| 23 | `bobbing-dots` | `/tmp/amicro/registry/ui/bobbing-dots.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 24 | `bounce-dots` | `/tmp/amicro/registry/ui/bounce-dots.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 25 | `bouncing-bars` | `/tmp/amicro/registry/ui/bouncing-bars.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 26 | `bouncing-dots` | `/tmp/amicro/registry/ui/bouncing-dots.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 27 | `bouncing-lines` | `/tmp/amicro/registry/ui/bouncing-lines.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 28 | `bouncing-square` | `/tmp/amicro/registry/ui/bouncing-square.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 29 | `breathe-ring` | `/tmp/amicro/registry/ui/breathe-ring.json` | **改造** | 等待状态 | 仅低频且状态限定；优先现有 phase glyph |
| 30 | `breathing-glow` | `/tmp/amicro/registry/ui/breathing-glow.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 31 | `breathing-square` | `/tmp/amicro/registry/ui/breathing-square.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 32 | `card-hover` | `/tmp/amicro/registry/ui/card-hover.json` | **改造** | 任务行/画廊卡片 | 折叠进原生 hover surface，不复制 Web card |
| 33 | `character-stagger` | `/tmp/amicro/registry/ui/character-stagger.json` | **改造** | Onboarding/完成成果标题 | 仅短文案可用；中文逐字需克制 |
| 34 | `circular-bars` | `/tmp/amicro/registry/ui/circular-bars.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 35 | `classic-spinner` | `/tmp/amicro/registry/ui/classic-spinner.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 36 | `clock-spinner` | `/tmp/amicro/registry/ui/clock-spinner.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 37 | `comet-spinner` | `/tmp/amicro/registry/ui/comet-spinner.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 38 | `concentric-pulse` | `/tmp/amicro/registry/ui/concentric-pulse.json` | **改造** | 空状态接收点 | 与已采用 ripple 合并，不能叠两套 |
| 39 | `concentric-ring` | `/tmp/amicro/registry/ui/concentric-ring.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 40 | `concentric-squares` | `/tmp/amicro/registry/ui/concentric-squares.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 41 | `conveyor-loop` | `/tmp/amicro/registry/ui/conveyor-loop.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 42 | `cross-spinner` | `/tmp/amicro/registry/ui/cross-spinner.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 43 | `cube-flip-spring` | `/tmp/amicro/registry/ui/cube-flip-spring.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 44 | `cursor-trail` | `/tmp/amicro/registry/ui/cursor-trail.json` | **不适用** | — | Mac 原生指针不应添加拖尾/吸附点；spotlight 已覆盖有效反馈 |
| 45 | `dash-ring` | `/tmp/amicro/registry/ui/dash-ring.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 46 | `dashed-spiral` | `/tmp/amicro/registry/ui/dashed-spiral.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 47 | `diamond-grid` | `/tmp/amicro/registry/ui/diamond-grid.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 48 | `diamond-rotate-spring` | `/tmp/amicro/registry/ui/diamond-rotate-spring.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 49 | `dot-spinner` | `/tmp/amicro/registry/ui/dot-spinner.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 50 | `dots-ring` | `/tmp/amicro/registry/ui/dots-ring.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 51 | `double-ring` | `/tmp/amicro/registry/ui/double-ring.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 52 | `drop-dot` | `/tmp/amicro/registry/ui/drop-dot.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 53 | `dual-arc` | `/tmp/amicro/registry/ui/dual-arc.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 54 | `dynamic-island` | `/tmp/amicro/registry/ui/dynamic-island.json` | **改造** | 进度 Hero 状态胶囊 | 只借固定几何内状态切换；不复制 iPhone 外形 |
| 55 | `elastic-bars` | `/tmp/amicro/registry/ui/elastic-bars.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 56 | `elastic-square` | `/tmp/amicro/registry/ui/elastic-square.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 57 | `expanding-cross` | `/tmp/amicro/registry/ui/expanding-cross.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 58 | `face-id-scan` | `/tmp/amicro/registry/ui/face-id-scan.json` | **改造** | Paste Anything 识别语义 | 只取 scan→success 编排，不复制 Face ID 外形 |
| 59 | `fade-arc` | `/tmp/amicro/registry/ui/fade-arc.json` | **改造** | 统一进入/离场 primitive | 折叠进 AmicroReveal，避免为每方向维护独立类 |
| 60 | `fade-dots` | `/tmp/amicro/registry/ui/fade-dots.json` | **改造** | 统一进入/离场 primitive | 折叠进 AmicroReveal，避免为每方向维护独立类 |
| 61 | `fade-down` | `/tmp/amicro/registry/ui/fade-down.json` | **改造** | 弹出层离场 | 并入统一 reveal/exit primitive |
| 62 | `fade-in` | `/tmp/amicro/registry/ui/fade-in.json` | **改造** | 轻量内容进入 | 并入统一 reveal primitive，避免重复类 |
| 63 | `fade-up` | `/tmp/amicro/registry/ui/fade-up.json` | **采用** | 主窗口空状态 | AmicroReveal 一次性进入 |
| 64 | `flip-square` | `/tmp/amicro/registry/ui/flip-square.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 65 | `floating-diamonds` | `/tmp/amicro/registry/ui/floating-diamonds.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 66 | `fluid-bars` | `/tmp/amicro/registry/ui/fluid-bars.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 67 | `fluid-diamond` | `/tmp/amicro/registry/ui/fluid-diamond.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 68 | `fluid-dot-orbit` | `/tmp/amicro/registry/ui/fluid-dot-orbit.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 69 | `fluid-skeleton` | `/tmp/amicro/registry/ui/fluid-skeleton.json` | **改造** | Link Lens/封面加载 | 只取流动高光，禁独立假加载时长 |
| 70 | `gears` | `/tmp/amicro/registry/ui/gears.json` | **不适用** | — | 具象 demo/品牌隐喻，不对应下载交付状态 |
| 71 | `glassmorphic-card` | `/tmp/amicro/registry/ui/glassmorphic-card.json` | **不适用** | — | 展示型 Web 外观，与 NDM 原生信息架构不一致 |
| 72 | `glow-button` | `/tmp/amicro/registry/ui/glow-button.json` | **采用** | Paste Anything 主/次动作 | 指针位置驱动 radial glow |
| 73 | `gradient-arc` | `/tmp/amicro/registry/ui/gradient-arc.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 74 | `grid-dots` | `/tmp/amicro/registry/ui/grid-dots.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 75 | `haptic-ring` | `/tmp/amicro/registry/ui/haptic-ring.json` | **改造** | 完成/复制反馈 | Mac 改视觉与 VoiceOver notification，不使用 Web Haptics |
| 76 | `heartbeat` | `/tmp/amicro/registry/ui/heartbeat.json` | **不适用** | — | 具象 demo/品牌隐喻，不对应下载交付状态 |
| 77 | `hexagon-spinner` | `/tmp/amicro/registry/ui/hexagon-spinner.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 78 | `hourglass` | `/tmp/amicro/registry/ui/hourglass.json` | **改造** | waiting/incomplete 状态 | 改成静态/短循环 native symbol，不独立 Web loader |
| 79 | `infinity-path` | `/tmp/amicro/registry/ui/infinity-path.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 80 | `intersecting-rings` | `/tmp/amicro/registry/ui/intersecting-rings.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 81 | `ios-spinner` | `/tmp/amicro/registry/ui/ios-spinner.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 82 | `line-spinner` | `/tmp/amicro/registry/ui/line-spinner.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 83 | `liquid-dots` | `/tmp/amicro/registry/ui/liquid-dots.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 84 | `mac-terminal` | `/tmp/amicro/registry/ui/mac-terminal.json` | **不适用** | — | 展示型 Web 外观，与 NDM 原生信息架构不一致 |
| 85 | `magnetic-button` | `/tmp/amicro/registry/ui/magnetic-button.json` | **采用** | Paste Anything 主/次动作 | 原生 spring 150/15/0.6，限制 18% 偏移 |
| 86 | `magnetic-dots` | `/tmp/amicro/registry/ui/magnetic-dots.json` | **不适用** | — | Mac 原生指针不应添加拖尾/吸附点；spotlight 已覆盖有效反馈 |
| 87 | `minimal-triangle` | `/tmp/amicro/registry/ui/minimal-triangle.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 88 | `morph-dot-ring` | `/tmp/amicro/registry/ui/morph-dot-ring.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 89 | `morph-loader` | `/tmp/amicro/registry/ui/morph-loader.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 90 | `morphing-bars` | `/tmp/amicro/registry/ui/morphing-bars.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 91 | `morphing-infinity` | `/tmp/amicro/registry/ui/morphing-infinity.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 92 | `morphing-ring` | `/tmp/amicro/registry/ui/morphing-ring.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 93 | `morphing-shape` | `/tmp/amicro/registry/ui/morphing-shape.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 94 | `mouse-follow` | `/tmp/amicro/registry/ui/mouse-follow.json` | **不适用** | — | Mac 原生指针不应添加拖尾/吸附点；spotlight 已覆盖有效反馈 |
| 95 | `newtons-cradle` | `/tmp/amicro/registry/ui/newtons-cradle.json` | **不适用** | — | 具象 demo/品牌隐喻，不对应下载交付状态 |
| 96 | `offset-rings` | `/tmp/amicro/registry/ui/offset-rings.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 97 | `orbiting-circles` | `/tmp/amicro/registry/ui/orbiting-circles.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 98 | `orbiting-dot` | `/tmp/amicro/registry/ui/orbiting-dot.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 99 | `origami-shape` | `/tmp/amicro/registry/ui/origami-shape.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 100 | `pendulum` | `/tmp/amicro/registry/ui/pendulum.json` | **不适用** | — | 具象 demo/品牌隐喻，不对应下载交付状态 |
| 101 | `progress-indicator` | `/tmp/amicro/registry/ui/progress-indicator.json` | **采用** | ThinProgressView 全产品进度面 | 真实进度 spring 0.1/100/20 |
| 102 | `pulsating-dots` | `/tmp/amicro/registry/ui/pulsating-dots.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 103 | `pulse-dot` | `/tmp/amicro/registry/ui/pulse-dot.json` | **改造** | 工具栏活动指示 | 与 activity pulse 合并 |
| 104 | `pulse-dots` | `/tmp/amicro/registry/ui/pulse-dots.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 105 | `pulse-square` | `/tmp/amicro/registry/ui/pulse-square.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 106 | `pulse` | `/tmp/amicro/registry/ui/pulse.json` | **改造** | 工具栏活动指示 | 改为 Reduce Motion 门控的原生 pulse |
| 107 | `pumping-heart` | `/tmp/amicro/registry/ui/pumping-heart.json` | **不适用** | — | 具象 demo/品牌隐喻，不对应下载交付状态 |
| 108 | `radar-sweep` | `/tmp/amicro/registry/ui/radar-sweep.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 109 | `ring-sweep` | `/tmp/amicro/registry/ui/ring-sweep.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 110 | `ripple-effect` | `/tmp/amicro/registry/ui/ripple-effect.json` | **采用** | Paste Anything 接收点、Smart Delivery 完成 | 三层单次/受状态约束 ripple |
| 111 | `rotating-cross` | `/tmp/amicro/registry/ui/rotating-cross.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 112 | `rotating-triangle` | `/tmp/amicro/registry/ui/rotating-triangle.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 113 | `scale-in` | `/tmp/amicro/registry/ui/scale-in.json` | **采用** | 空状态与成果 reveal | 并入 AmicroReveal 的 0.9→1 |
| 114 | `scroll-reveal` | `/tmp/amicro/registry/ui/scroll-reveal.json` | **不适用** | — | NDM 是固定桌面工作区，不以页面滚动驱动核心状态 |
| 115 | `shape-shift-grid` | `/tmp/amicro/registry/ui/shape-shift-grid.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 116 | `shimmer-line` | `/tmp/amicro/registry/ui/shimmer-line.json` | **改造** | Link Lens skeleton | 折叠到已采用 skeleton shimmer |
| 117 | `siri-wave` | `/tmp/amicro/registry/ui/siri-wave.json` | **改造** | 音频提取 running | 去 Siri branding 后才可作为 waveform |
| 118 | `skeleton-loader` | `/tmp/amicro/registry/ui/skeleton-loader.json` | **改造** | Link Lens/封面加载 | 改为真实内容尺寸 skeleton，已由 skeleton 覆盖 |
| 119 | `skeleton` | `/tmp/amicro/registry/ui/skeleton.json` | **采用** | Link Lens 识别/封面加载 | 1.6s shimmer，真实状态结束即停止 |
| 120 | `slide-left` | `/tmp/amicro/registry/ui/slide-left.json` | **改造** | 检查器/详情内容切换 | 改为固定容器内 8pt 位移 |
| 121 | `slide-right` | `/tmp/amicro/registry/ui/slide-right.json` | **改造** | 检查器/详情内容切换 | 改为固定容器内 8pt 位移 |
| 122 | `sliding-bars` | `/tmp/amicro/registry/ui/sliding-bars.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 123 | `smooth-dot-shift` | `/tmp/amicro/registry/ui/smooth-dot-shift.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 124 | `smooth-ring` | `/tmp/amicro/registry/ui/smooth-ring.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 125 | `smooth-rounded-square` | `/tmp/amicro/registry/ui/smooth-rounded-square.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 126 | `spinning-squares` | `/tmp/amicro/registry/ui/spinning-squares.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 127 | `spiral-spinner` | `/tmp/amicro/registry/ui/spiral-spinner.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 128 | `spotlight` | `/tmp/amicro/registry/ui/spotlight.json` | **采用** | Gallery artwork | 原生 CAGradientLayer 指针 spotlight |
| 129 | `spring-bars` | `/tmp/amicro/registry/ui/spring-bars.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 130 | `spring-dot-matrix` | `/tmp/amicro/registry/ui/spring-dot-matrix.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 131 | `spring-hexagon` | `/tmp/amicro/registry/ui/spring-hexagon.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 132 | `spring-ring-expand` | `/tmp/amicro/registry/ui/spring-ring-expand.json` | **改造** | 完成反馈 | 折叠到一次性 ripple/success ring |
| 133 | `spring-text-pop` | `/tmp/amicro/registry/ui/spring-text-pop.json` | **改造** | 速度/百分比数字 | NDM 现有滚动数字更完整，仅保留 settle 参数 |
| 134 | `square-accordion` | `/tmp/amicro/registry/ui/square-accordion.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 135 | `square-grid` | `/tmp/amicro/registry/ui/square-grid.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 136 | `square-snake` | `/tmp/amicro/registry/ui/square-snake.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 137 | `square-spinner` | `/tmp/amicro/registry/ui/square-spinner.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 138 | `stacked-bar-pulse` | `/tmp/amicro/registry/ui/stacked-bar-pulse.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 139 | `sticky-reveal` | `/tmp/amicro/registry/ui/sticky-reveal.json` | **不适用** | — | NDM 是固定桌面工作区，不以页面滚动驱动核心状态 |
| 140 | `swapping-dots` | `/tmp/amicro/registry/ui/swapping-dots.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 141 | `swirling-spinner` | `/tmp/amicro/registry/ui/swirling-spinner.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 142 | `symmetric-wave` | `/tmp/amicro/registry/ui/symmetric-wave.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 143 | `terminal-loader` | `/tmp/amicro/registry/ui/terminal-loader.json` | **不适用** | — | 展示型 Web 外观，与 NDM 原生信息架构不一致 |
| 144 | `text-blink` | `/tmp/amicro/registry/ui/text-blink.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 145 | `text-dots` | `/tmp/amicro/registry/ui/text-dots.json` | **改造** | 等待 metadata | 可并入状态标签，不能固定 setTimeout |
| 146 | `text-morph` | `/tmp/amicro/registry/ui/text-morph.json` | **采用** | NowDownloadingHero 阶段文案 | 旧文案上退、新文案下入 |
| 147 | `text-reveal` | `/tmp/amicro/registry/ui/text-reveal.json` | **改造** | Onboarding/空状态 | 折叠到 WordReveal/AmicroReveal |
| 148 | `text-shimmer-wave` | `/tmp/amicro/registry/ui/text-shimmer-wave.json` | **改造** | 识别中短标签 | 只可状态限时；不可常驻循环 |
| 149 | `text-shimmer` | `/tmp/amicro/registry/ui/text-shimmer.json` | **改造** | 识别中短标签 | 只可状态限时；当前 skeleton 已足够 |
| 150 | `tilt-card` | `/tmp/amicro/registry/ui/tilt-card.json` | **采用** | Gallery artwork | 原生 spring，15° 收敛为 ±4° |
| 151 | `classic-toggle` | `/tmp/amicro/registry/ui/toggles/classic-toggle.json` | **不适用** | — | 使用 NSButton/系统 toggle；且仓库声明源码缺失 |
| 152 | `trailing-dots` | `/tmp/amicro/registry/ui/trailing-dots.json` | **改造** | 等待 metadata | 可并入状态标签，不能固定 setTimeout |
| 153 | `triple-dot-spinner` | `/tmp/amicro/registry/ui/triple-dot-spinner.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 154 | `twin-orbit` | `/tmp/amicro/registry/ui/twin-orbit.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 155 | `typing-indicator` | `/tmp/amicro/registry/ui/typing-indicator.json` | **改造** | 等待 relay/metadata | 绑定真实等待状态后才可用 |
| 156 | `typing` | `/tmp/amicro/registry/ui/typing.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 157 | `wandering-cube` | `/tmp/amicro/registry/ui/wandering-cube.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 158 | `watch-spinner` | `/tmp/amicro/registry/ui/watch-spinner.json` | **不适用** | — | 具象 demo/品牌隐喻，不对应下载交付状态 |
| 159 | `wave-dots` | `/tmp/amicro/registry/ui/wave-dots.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 160 | `wave-physics-loader` | `/tmp/amicro/registry/ui/wave-physics-loader.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 161 | `waveform-loader` | `/tmp/amicro/registry/ui/waveform-loader.json` | **改造** | 音频提取 running | 可替换 spinner，但需性能/Reduce Motion 评估 |
| 162 | `word-reveal` | `/tmp/amicro/registry/ui/word-reveal.json` | **采用** | 主窗口 Paste Anything 空状态 | 40ms stagger 与一次性 reveal |
| 163 | `zig-zag-pulse` | `/tmp/amicro/registry/ui/zig-zag-pulse.json` | **不适用** | — | 同质持续循环 loader/展示动效；不绑定真实进度，且源实现无 Reduce Motion |
| 164 | `zoom-in` | `/tmp/amicro/registry/ui/zoom-in.json` | **改造** | 完成结果一次性进入 | 折叠到 AmicroReveal，禁循环 |

## Registry 外已采用模式

下列高价值模式不计入上述 164 个 registry JSON，但已包含在全仓 TS/TSX 审计中：

- `src/components/IconSwap.tsx` → `AmicroIconSwapView`，接入任务行、进度动作和音频提取成功/失败。
- `src/components/PageTransition*.tsx` → 不复制全屏 wipe；只把“共享视觉落位后再揭示内容”的编排并入现有 620ms Smart Delivery handoff。
- `src/components/AnimatedButton.tsx` / `src/data/buttons.tsx` → hover 1.02、press 0.96、spring 600/25，接入原生任务行 action rail。

## 已知源仓问题

- `classic-toggle` 的 JSON 含源码，但声明的磁盘 TSX 缺失。
- `progress-indicator.tsx` 含重复 JSX `style` 属性；NDM 只移植参数与语义，不复制 React 文件。
- 多数示例用 `repeat: Infinity` 或固定 `setTimeout` 假装完成；NDM 全部要求绑定真实 coordinator/engine state。
