# 需求证据与功能候选

2026-07-25。这份文件的规则只有一条：**每个候选必须挂住至少一句真实用户原话**。
没有原话支撑的想法不写进来 —— 之前两轮（内建转写、直播录制）就是靠"竞品没做"推出来的，
两次都错。原始检索结果（Tavily / reddit + v2ex + 知乎，约 900KB）在会话 scratchpad。

判据借用一句检索时捡到的话，它比我自己的框架好：

> "The best signal isn't just complaints — it's complaints paired with spending.
> Someone saying 'X is annoying' is weak signal. Someone saying **'I pay for Y, hate it,
> but keep using it because there's nothing better'** — that's the idea."
> — [r/Solopreneur](https://www.reddit.com/r/Solopreneur/comments/1s2wenn/i_stopped_brainstorming_startup_ideas_and_started)

按这条判据排序，不按"听起来酷"排序。

---

## P0 —— 付了钱的人正在骂的事

这一层是「已付费 + 仍然痛」，付费意愿已被证明，只是被竞品浪费了。

### P0-1 引擎失效当保修处理

**原话**

- 帖子标题：「downie 突然不能下载 youtube 视频了」
  ([v2ex/1087596](https://v2ex.com/t/1087596))
- "Some methods I've seen online either don't work anymore or seem sketchy. Recently,
  many sites/tools stopped working because of YouTube's restrictions."
  ([r/downr](https://www.reddit.com/r/downr/comments/1lsucqo/best_way_to_download_youtube_videos))
- "Happy to pay for high quality software, but **if it just turns into abandon-ware at the
  stroke of midnight I don't feel safe investing any time in it.**"
  ([r/MacOS](https://www.reddit.com/r/MacOS/comments/1g6vlze/best_video_downloaders_for_macos_and_why))
- 4K Downloader 买断用户："**total scammers!** After paying for 'lifetime' … you will need to
  buy their 'NEW' software again that does the exact same thing"
  ([r/software](https://www.reddit.com/r/software/comments/1cbchv0/is_4k_downloader_safe))

**候选做什么**

不是一个功能，是一条承诺加上支撑它的机制：
- 站点适配失效可自我上报（用户一键提交失败样本，不含内容、只含 URL 形态与失败阶段）
- 适配规则与 yt-dlp 可独立于 App 版本更新，失效修复不排在下一个大版本后面
- 买断，且把"引擎失效属于保修范围"写进购买页

**为什么排第一**：它同时消解两族最强痛点 —— 「不能用了」和「买断被背刺」。竞品收了钱
然后放着坏掉，这是可以正面攻击的位置。

### P0-2 交付正确性：不给坏文件，也不谎报成功

**原话**

- "正常下载 Android studio，**断了好多次没法重新下载**"
  ([v2ex/1198472](https://www.v2ex.com/t/1198472))
- "I spend a lot of time travelling, so my internet is restricted and not always with a good
  connection. So, I'm looking for **reliable** download manager"
  ([r/macapps](https://www.reddit.com/r/macapps/comments/12rgs1w/download_manager))
- B 站音视频分离导致"下载视频后找不到对应音频"、IDM"下载后缺少音频"
  ([v2ex/685519](https://v2ex.com/t/685519))

**候选做什么**：已在做的静默错误家族继续做完 —— HLS 密钥轮换、容器名与真实格式一致、
POST 语义、失败删除不毁 resume、`DeliveryNote` 呈现。加上一条新的：**交付前自检**
（时长/轨道/可解码），不通过就说不通过，不要交一个能打开却没有声音的文件。

**注意宣传口径**：用户买的不是带宽。r/software 有整帖在问
[「Is a Download Manager worth it? Do they really provide any benefit?」](https://www.reddit.com/r/software/comments/1ccw1zw/is_a_download_manager_idm_for_example_worth_it)
—— "更快"不值钱，**"大文件不会白下一遍"**值钱。

---

## P1 —— 我们有独特钥匙的事

### P1-1 登录态直通：已登录页面里能播的，就能存下来

**原话**

- "下载引擎是底层 yt-dlp 提供的，**你这是被风控了**"（用户读不到浏览器 Cookie）
  ([v2ex/1168398](https://www.v2ex.com/t/1168398))
- 同帖用户追问支持不支持 **保利威、B 站充电视频**
- "YouTube 貌似现在**有的视频需要登录才能下载了**"
  ([v2ex/1087596](https://v2ex.com/t/1087596))
- 钉钉录播："即便能抓取 m3u8 链接，也遇到解析失败问题"；研直播录播："我尝试了一些
  chrome 插件 和 you-get 都没成功" ([v2ex/815221](https://v2ex.com/t/815221))
- 竞品把这点当核心卖点写："B 站的 1080P 高码率、4K 甚至 8K 画质和杜比全景声，**都需要账号
  权限** … 掏出手机 B 站客户端扫一扫即可。**你的登录状态只会保存在本地，非常安全**"
  ([知乎](https://www.zhihu.com/tardis/jm/art/2036177210780934988))

**为什么这是我们的位置**：NDM Relay 扩展就在页面里，用户已经登录了。yt-dlp 拿不到会话，
在线站点拿不到，Downie 只能靠自己抽取。这句话只有我们说得出口，而它同时解决 P0-1
（不失效）和付费/权限内容。**这是目前手里最被低估的资产。**

**候选做什么**：把扩展从"嗅探链接"升级为"携带会话的采集通道" —— 会话只留在本地、
不出机器、可随时清除，并且在 UI 上明说这一点（安全承诺本身是卖点，见 P1-2）。

### P1-2 干净可信：不塞捆绑、不弹广告、不吃 CPU

**原话**

- 帖子标题：**"Is there a free YouTube video downloader that doesn't give me like 50 viruses?
  Seriously, please."**
  ([r/youtube](https://www.reddit.com/r/youtube/comments/1i68vz8/is_there_a_free_youtube_video_downloader_that))
- 4K Downloader："**several instances of malware were detected. Malicious startup scripts upon
  reboot** as well. Avoid at all costs."
  ([r/software](https://www.reddit.com/r/software/comments/1cbchv0/is_4k_downloader_safe))
- JDownloader："it forcibly installed AVG Secure Browser … and CCleaner onto my PC. Not cool."
  / **"The software is safe, but the installer is not."**
  ([r/software](https://www.reddit.com/r/software/comments/1c5hjiz/is_jdownloader_2_really_as_safe_as_people_claim))
- 知乎把它列成选工具第三条标准："**担心安全**：怕装到带广告或木马的野鸡工具"
  ([知乎](https://www.zhihu.com/tardis/jm/ans/2062833701508093137))
- "4K video downloader works well but **the ads for premium get annoying**"

**外加一条没人主打过的**：

- "once I start downloading with this thing, **it chews through CPU cycles with an unlimited
  appetite, sends my poor Macbook's fans whirring uncontrollably, and slows the whole system
  down.**" ([r/firefox](https://www.reddit.com/r/firefox/comments/f6kouj/video_download_helper_on_mac_anyone_getting))
- 竞品把降 CPU 当版本亮点写进 FAQ："最新版本已经优化了限制机制，**有效降低了 CPU 占用**"
  ([知乎](https://www.zhihu.com/tardis/jm/art/2036177210780934988))

**候选做什么**：公证签名 + 无捆绑 + 无广告 + 无遥测（或明确可关且默认关），把这些写在
购买页而不是埋在隐私政策里。工程侧：合并/解密阶段的 CPU 与磁盘写入设上限并可见 ——
**"下载时 Mac 不烫、风扇不叫"是一句还没人抢的宣传语**。

> 内部注：`NDMSoak` 那次 710 GB / 94% CPU 事故说明这条痛点真实存在，我们自己也刚被烫过。

---

## P2 —— UI 值得投，但要认清它在链条里的位置

**支持你判断的原话**

- 有人只看官网截图就想换掉付费软件："**看官网感觉 App 的 UI 应该不错，Downie 有点丑**"
  ([v2ex/1145257](https://www.v2ex.com/t/1145257))
- 整个品类的问题被总结成一句："**要么 UI 土得掉渣乱七八糟，要么功能乱七八糟，是纯命令行
  用着又太难受**" ([v2ex/1168398](https://www.v2ex.com/t/1168398))
- 用户用 UI 现代程度给下载器排序（NDM 就在被排的那一档）："Neat Download Manager ——
  **UI 比较古早**"；"Brisk —— Flutter 写的 UI，**比上面那款更现代一丢丢**"
  ([v2ex/1198472](https://www.v2ex.com/t/1198472))
- "界面看着很古老就算了，价格也很惊人" ([cn.v2ex/1015380](https://cn.v2ex.com/t/1015380))
- 推荐文把"好看"当主论点："**它抛弃了传统开源软件复杂的命令行黑框框，拥有非常符合现代
  审美的图形界面**" ([知乎](https://www.zhihu.com/tardis/jm/art/2036177210780934988))

**反面证据，必须一起记**

- "IDM 虽然 UI 不太好看，但**功能比 Downie 好用**" ([cn.v2ex/1015380](https://cn.v2ex.com/t/1015380))
- "**现在没人愿意花时间做 gui 了，反正命令行能用就够了**"（同帖）

**结论**：UI 决定**谁被下载、被推荐、被写进文章、截图被传播** —— 它是进入候选池的门票，
也是"这是专业设计师做的"这个信任信号的载体。但**留下来**靠"它真的下得下来"。

**由此推出一条硬约束**：因为 UI 在这个品类里承担信任信号，**半成品动画的损失大于普通
bug**。一个抖一下的落位动画会把"专业"这个信号打碎，比没有动画更糟。
→ Hero 落位要么做到稳，要么砍掉复杂度。不允许长期停在 wip。

---

## 不做 / 降级

| 项 | 原因 | 证据 |
|---|---|---|
| 纯 YouTube 下载当主卖点 | 红海，第一替代品是免费开源 yt-dlp，另有 19 个免费 Mac 替代 | "单纯下 YouTube 真是一抓一大把啊" ([cn.v2ex/1015380](https://cn.v2ex.com/t/1015380))；[alternativeto](https://alternativeto.net/software/downie/?platform=mac) |
| 内建转写当护城河 | 即将成为桌面标配，不是差异点 | Grabcube 自称"完全可以替代 Downie"，已打 AI 转写 + 多语言字幕翻译 ([v2ex/1145257](https://www.v2ex.com/t/1145257)) |
| DRM 内容（Netflix / Prime） | 硬墙，且触碰即越界 | 需求确实旺（"I just want to download shows to my MacBook" [r/MacOS](https://www.reddit.com/r/MacOS/comments/o760nj/can_someone_tell_me_why_there_is_still_no_netflix)），但 Downie 用户也知道 "It can't download Netflix videos or anything similarly encrypted" |
| 多线程速度当宣传语 | 用户不为带宽付钱 | 整帖在问 "Do they really provide any benefit?" ([r/software](https://www.reddit.com/r/software/comments/1ccw1zw/is_a_download_manager_idm_for_example_worth_it)) |
| 直播录制 | 无需求证据，仅一例问询 | 已在前一轮被否 |

---

## 法律风险（记录，不是候选）

有用户当面提出，不能装作没看见：

> "境外：youtube-dl 惨遭下架、承担连带责任 境内：90 后小伙，用软件非法搬运他人原创视频
> 被判刑" / **"工具无罪论不存在的"** / "现在大部分网站都是做了技术限制的，政策上就不允许
> 个人下载"（MindMindMax，[v2ex/1145257](https://www.v2ex.com/t/1145257)）

影响定位口径：站在**个人离线留存自己有权访问的内容**（网课、自己的会议录播、公开资料），
不站在"搬运"。P1-1 的登录态直通天然落在这一侧 —— 用户下载的是自己账号能看的东西。

---

## 定价（证据已经钉死）

**买断，不订阅。** 并把"引擎失效属于保修"写进购买页。

- "**I don't rent software either.** Happy to pay for high quality software"
- "I bought a lifetime license expecting all updates but then **they rolled out that '+' version
  on me**"
- "Any Video Converter **specifically version 9.0.5 before they forced everything to a
  subscription service**"
- 买断带来的信任可量化："idm 很好用 当初买 129，这么多年 118 还降价了呢"
  ([cn.v2ex/1015380](https://cn.v2ex.com/t/1015380))

**中国区的硬现实，一并记住**：

- "你在国内跟人说要付费去 appstore，**人家反手给你几个问号**"
- "回头想起来自己买了好多苹果端功能不怎么样的软件。。。**后悔 ing**"
  ([cn.v2ex/853714](https://cn.v2ex.com/t/853714))

但同一批人列自己愿意买断的东西时毫不犹豫：`Infuse Pro 终身`、`1Password`、
`Surge（一分钱一分货）`、`IDM`、`Plex 终身`（[hk.v2ex/951081](https://hk.v2ex.com/t/951081)）。
→ 中国用户不是不付钱，是不为"功能不怎么样"付钱。「一分钱一分货」是可以挣到的。

---

## 与 NORTHSTAR 的关系

`NORTHSTAR.md` 是执行顺序与进度日志，这份是**为什么做**的证据底账。
两者冲突时以证据为准，并回头改 NORTHSTAR。
