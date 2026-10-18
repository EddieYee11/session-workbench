# Meta Muse × Hark Pro 深度调研：设计语言、运行逻辑、开源借用与 Com! 手搓方案（查询日期 2026-10-10）

> 来源：Eddie 用 Claude 写的调研 Prompt 跑 Deep Research 得到的报告，原文保存于此（2026-10-10）。
> 文末「对照 Com! 现状」一节是 Claude 当天对照代码和 mini 实时数据做的核对，不属于原报告。
> 原报告里产品事实（发布日期、定价、架构）未经 Claude 独立联网核实；开源项目数据请 clone 前到 GitHub 复核。

先说结论：Meta 的 Muse 是 2026-09-08 发布的消费级个人 Agent（不是 Muse Spark 模型，也不是微软的 Muse 游戏模型）。「hark.pro」对应的是 Hark Labs 在 2026-10-06 发布的 **Hark Pro**，官方域名是 hark.com，不是 hark.pro。两家走的是同一条路线：每个用户一台云端电脑，加长期记忆、主动卡片和批准流，但取舍正好相反。你的 Com! 应该照抄 Muse 的「确定性批准卡 + 可编辑记忆文件 + 活动日志」，再照抄 Hark 的「首页主动卡片 + 一键动作按钮」。云端 VM、浏览器代购、支付钱包这几块直接砍掉；你已经在用的 Hermes Agent，加上 Hindsight / mem0 和一组 MCP 连接器，基本就够了。

## TL;DR

- **对象已对齐**：Meta Muse = muse.ai 个人 Agent。2026-09-08 发布，iOS / Android / Web / WhatsApp，底座模型 Muse Spark 1.3，免费 + $20 / $100 档。Hark Pro = Brett Adcock 的 Hark Labs 出品，2026-10-06 发布，Web / iOS / Android，免费 + $20（2 倍用量）/ $100（10 倍用量），底座是自研电脑操作模型 Handoff。用户写的「hark.pro」不是官方域名。
- **最值得抄的设计判断**：Muse 把「需要批准」放进对话之外的确定性 UI，审批是严格的能力授权，不是聊天建议；同时公开活动日志、权限和可直接编辑的记忆文件。Hark 把通知改造成「Action Buttons」，一张卡对应一个动词按钮（Pay / Cancel），并且故意把步骤分批、在恰当时机推送，不一次性堆进聊天。
- **落地路径**：Com! 不需要云端 VM 和 Sentinel 这种多租户隔离。用 FastAPI 里的确定性策略层（allow / deny / ask）替代 Sentinel；记忆用 Hindsight（MIT）或 mem0（Apache-2.0）配合可编辑的 Markdown 记忆文件；连接器用 EWS / Garmin / GitHub 的 MCP server。三周内可以演示「事件 → 评分 → 合并 → 发卡 → 批准 → 执行 → 验收」全链路。

---

## 1. 对齐对象与一手资料

**本节摘要**
1. 「Meta Muse」有 5 个同名候选，按「2025–2026 年、面向消费者、个人 Agent 应用」的标准，只有 2026-09-08 发布的 Muse 符合。
2. Hark Pro 由 Hark Labs（创始人 Brett Adcock，设计负责人 Abidur Chowdhury）出品，官方域名是 hark.com，没有证据表明 hark.pro 属于官方。
3. 两家的一手资料都很充足：官方设计博客、安全白皮书、帮助页、隐私政策、App Store 页、发布视频。Muse 的安全文档质量明显高于 Hark。
4. 公开截图都没有官方 Design Token。本报告**没有**从截图里取十六进制色值，避免编造。

### 1.1 「Meta Muse」候选清单与选择理由

| 候选 | 是什么 | 时间 | 是否入选 |
|---|---|---|---|
| **Muse（个人 AI Agent，muse.ai）** | Meta 消费级个人 Agent，独立 App + WhatsApp | 2026-09-08 发布 | ✅ 入选：唯一同时满足「消费级」「个人 Agent」「2025–2026」三个条件 |
| Muse Spark（1.0 / 1.1 / 1.2 / 1.3） | Meta Superintelligence Labs 的闭源大模型家族，Muse Agent 的底座 | 首版 2026-04-08 | ❌ 是模型，不是应用 |
| Muse Code | 终端编程 Agent，基于 Muse Spark 1.2 | 2026-08-05 | ❌ 面向开发者 |
| Muse Image / Muse Video | 图像 / 视频生成模型 | Muse Image 2026-07-07 | ❌ 生成模型 |
| 微软 Muse（WHAM 游戏世界模型） | 微软研究院的游戏生成模型（2025 年发布，本次未重新核实细节） | 2025 | ❌ 同名，与 Meta 无关 |

**选择理由**：Meta Newsroom 的发布稿标题就是《Introducing Muse: The World's First Personal AI Agent Built for Everyone》，正文写明 Muse 运行在 Muse Secure VM 上，可以在 Muse App 或 WhatsApp 里像发消息一样使用，底层由 Muse Spark 驱动，在美国通过 iOS、Android 和 muse.ai 上线。

**补充事实（证据等级见括号）**
- 定价：CNBC 采访中 Alexandr Wang 称有免费档和 $20 / $100 两档月付订阅，用户需要主动选择退出，才能不让交互数据被用于训练（A，媒体直接引述官方）。
- 各档每周 token 额度：据 felloai.com 转述的 Meta 帮助中心《About Muse subscriptions》，帮助中心只列出两档付费额度，Power $20/月为每周「500 million Muse tokens」，Maximum $100/月为每周「3 billion」；免费档的每周 1 亿 token 不在帮助中心里（「The help page does not give a free allowance」），出处是 Zuckerberg 发布时在 X 上的帖子：「up to 100M tokens per week」（B，二手转述，本次没有直接打开帮助中心）。
- 9 月 23 日活动新增：Realtime Avatar 视频对话、控制 macOS 应用、Agent 自有邮箱地址（B，来源 Wikipedia 汇总）。
- 9 月 21 日 Amazon 在零售站封锁 Muse；有报道称 Meta 内部在测试「human agent layer」，由真人代打电话（B，媒体报道，Meta 未在官方博客中确认）。

### 1.2 Hark Pro 定位、团队、平台、定价、版本

| 维度 | 事实 | 证据 |
|---|---|---|
| 官方定位 | 「The operating system for your life」，自称「Not a chatbot, not a personal assistant, not an AI agent, not a cartoon character」 | A（官方发布稿） |
| 公司 | Hark Labs, Inc.，Brett Adcock（Figure AI、Archer 创始人）于 2025 年底创立，与 Figure 是两家独立公司 | A / B |
| 设计负责人 | Abidur Chowdhury，前 Apple 工业设计师，在 2025 年 9 月发布会上介绍过 iPhone Air，两个月后离职 | A（Gizmodo、TechCrunch） |
| 发布时间 | 2026-10-06 面向公众发布；电脑操作模型 Handoff 于 2026-08-05 以研究预览形式发布 | A |
| 平台 | Web、iOS、Android；App Store 描述还提到 iMessage；马来西亚区 App Store 显示可在 M1 Mac（macOS 14.6+）和 Vision Pro 上以 iPad 版运行 | A |
| 定价（官网） | 全部功能免费，但有用量上限；Hark Pro² $20/月 = 2 倍用量；Hark Pro³ $100/月 = 10 倍用量；支持自动充值 credits | A |
| 定价（美区 App Store 内购） | Pro² $26.00、Pro³ $129.99、**Pro⁴ $200.00**（官网未公布 Pro⁴） | A（App Store 页）。与官网价格**不一致**，推测是应用商店渠道加价，或有未公开档位（C） |
| 当前版本 | 美区 App Store 显示 2.2.0（「1 天前」，更新说明只有「Refinements to Hark」）；马来西亚区历史记录显示 1.0.1 发布于 9 月 18 日，说明 iOS 包早于公开发布就已上架 | A |
| 域名 | 官方是 hark.com；hark.ai 跳转到 hark.com；hark.dev 截至 10 月 8 日无内容。**没有找到 hark.pro 属于 Hark 的证据** | B |

### 1.3 一手资料清单（按价值排序）

**Muse**
- 发布稿（含 Sizzle、FieldTrip、Japan、Relationships、Shopping 共 5 段视频）：https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/
- 设计博客《How We Designed Muse》（Mona Sarantakos、Christine Awad）：https://introducing.muse.ai/
- 安全白皮书《How We Built Safety Into Muse》（Tarek Sheasha，约 20 分钟阅读）：https://security.muse.ai/ （canonical 地址：research.meta.ai/blog/security-and-safety-for-ai-agents-our-approach-with-muse）
- Product Design Lead Alex 的产品走查视频：https://www.youtube.com/watch?v=wHn0hTjvFoo
- Muse Spark 1.3 模型博客：https://research.meta.ai/blog/introducing-muse-spark-1-3
- 条款：https://muse.ai/terms ；隐私政策沿用 Facebook 隐私政策
- 招聘 JD：**没有找到 Muse 专属 JD**。themuse.com 的结果是同名招聘网站，属于噪音。

**Hark**
- 发布稿《Introducing Hark Pro》（含 7 段功能视频）：https://hark.com/articles/introducing-hark-pro
- 帮助页《Using Hark Pro》（信息架构说得最清楚的一份官方文档）：https://hark.com/using-hark
- Handoff 研究预览：https://hark.com/articles/introducing-hark-handoff
- 隐私政策：https://hark.com/privacy-policy ；条款：https://hark.com/terms ；安全页：https://hark.com/security
- App Store：https://apps.apple.com/us/app/hark-pro/id6772362941 ；Google Play：com.hark.android
- Product Hunt：https://www.producthunt.com/products/hark-3
- 创始人 / 设计访谈：TechCrunch 3 月专访 Chowdhury、TechCrunch 10 月 6 日发布报道、Gizmodo 10 月 6 日演示报道
- X：@hark_labs、@adcock_brett 的 Handoff 帖（8 月 5 日）和发布帖（10 月 6 日）
- 招聘页：https://hark.com/careers （本次未打开，JD 技术栈：**没有公开资料**）
- 更新日志：除了 App Store 的「Refinements to Hark」，**没有公开 changelog**

**关于视频逐帧与取色**：我没有逐帧观看这些 MP4，所以本报告**不引用任何视频时间点**，也**不给任何从截图提取的十六进制色值**。这两项需要你用 QuickTime 逐帧截图，再用 Digital Color Meter 自己取色。第 2 节给出的色值全部标注为「Com! 建议值（C）」，不是对方的真实值。

---

## 2. 设计语言拆解

**本节摘要**
1. Muse 是「一条长对话 + 头像状态 + 标签页（Goals / Ideas）」：主动消息和用户发起的对话**混在同一个主聊天流**里，用气泡分隔；复杂话题拆到 side chats。
2. Hark 是「三视图：Home / Chat / Projects」：主动事项**单独放在 Home 的卡片栈**，聊天只承担执行。
3. 两家都「刻意克制」：Muse 只在「有意义的新进展或需要输入」时才打扰；Hark 说话简短，把步骤分批，不一次堆满。
4. 视觉上，Muse 的个性来自可定制头像，Hark 的个性来自实时天空背景。两家都没有公开色板或字体规范。

### 2.1 Muse

**信息架构（文字版站点地图，A 级来自设计博客，标 C 的为推测）**
```
Muse App
├─ 主聊天（Main chat）—— 一条长对话；用户发起 + Agent 主动消息混排，用聊天气泡分段
│   ├─ Side chats —— 为复杂项目单独建上下文
│   ├─ Artifacts —— 富交互产物（行程、仪表盘、PDF、网页），可在聊天里发送，也可独立存在
│   └─ 批准卡（Approval cards）—— 结构化的接受 / 拒绝；由 Sentinel 直接推给客户端，不走对话
├─ 头像（Avatar）—— 下方显示「正在做什么」的一行摘要
│   └─ 点头像 → 完整活动日志 + 已授予的权限
├─ Goals 标签 —— 所有长期目标、追踪事项和计划
├─ Ideas 标签 —— Muse 根据目标、习惯和对话生成的建议
├─ Settings —— 权限默认值（更谨慎 / 更宽松）、训练 opt-out、连接器
├─ Memory files —— 可以直接阅读和编辑的记忆文件
└─ 浏览器视图 —— 可以实时观看并随时接管（白皮书 A）
```
- 通知 / 待办 / 记忆 / 连接器：主动消息进主聊天；待办与目标在 Goals；记忆在 Memory files；连接器与权限在 Settings 和头像详情。Ideas 是独立入口（A）。
- 一级入口的确切数量（底部 Tab 还是顶部切换）：**没有公开资料**，需要看 Alex 的走查视频确认（C）。

**视觉系统**
- 色值、字体、圆角、阴影：**没有公开资料**，本报告不提供截图取色值。
- 头像是视觉核心：用户可以自建头像、起名、定风格。设计负责人自己的 Muse 叫「Veda」（A）。
- 聊天气泡是一项被明确论证过的决策：消息会不按轮次到达，用户也会连发多条，没有边界的平铺记录会变得难读（A）。
- 是否使用 iOS 26 Liquid Glass：**没有公开资料**（C：Meta 系 App 通常使用自有设计系统，不太可能大面积采用原生 Glass）。

**核心界面逐屏**

| 屏 | 布局与控件 | 状态 | 证据 |
|---|---|---|---|
| 首页 / 主聊天 | 顶部是头像和状态摘要，下面是气泡流和输入框；可以打断，可以连发多条任务，不用等上一条回复 | 空态：首日用 onboarding tips 引导（A）；加载 / 失败的具体样式没有公开资料 | A / C |
| 主动消息 | 以普通气泡形式出现在主聊天；后台任务完成后先评估「值不值得提」，只有「有实质新进展」或「需要你输入」时才通知 | 「需要批准」时切换为结构化批准卡 | A |
| 批准卡 | 写明精确动作；可选授权范围：一次性 / 会话 / 任务 / 限时 / 永久；结账卡显示精确商品和金额 | 接受 / 拒绝；拒绝后 Sentinel 拒绝执行 | A（白皮书 + 设计博客 checkout 截图） |
| 任务 / 进度 | Goals 标签：目标 → 计划 → 追踪；可以直接操作，也可以回到聊天讨论 | 是否显示百分比没有公开资料 | A / C |
| 记忆 | 可读可编辑的记忆文件；也可以口头让它「forget」 | — | A |
| 活动日志 | 点头像打开；包含「已做」和「计划要做」的完整审计轨迹 | — | A |
| 设置 | 权限默认值的松紧档位；训练 opt-out 开关；连接器读 / 写分离 | — | A |

**动效与交互**
- Agent 状态的可视化：头像下方的「正在做」摘要，加上可观看的浏览器窗口（A）。打字机效果、光效、卡片进出场动效：**没有公开资料**（需要逐帧看视频）。
- 下拉 / 滑动 / 长按绑定：**没有公开资料**。

**写作口吻（官方原文摘录）**
1. 系统提示词第一行：「Your purpose is to make your user's life better.」
2. 「Muse doesn't just answer questions, it actually does the work.」
3. 「comes back when something changes or when it needs approval, like before it sends an email or makes a purchase」
4. 「a proactive message has to be genuinely helpful and worth the interruption」
5. 「you can always tell your Muse to turn it off, dial it down, or dial it up」
6. 「notifies you only when something is meaningfully new or needs your input」
7. 「You can't trust what you can't see」
8. 「stops for anything hard to undo」
9. 「they can always tell it to "forget" specific things it's learned」
- Agent 如何称呼用户、出错时的具体文案：**没有公开资料**。

**设计判断（刻意克制）**
- **避免「banner blindness」**：如果什么都问，用户就会为了让弹窗消失而全部点同意。所以默认只在不可逆动作上停下，常规浏览放行（A）。
- **把批准从对话里拿出来**：审批对话框直接在客户端 UI 中弹出，「不是通过与 Muse 的对话」，用户的回答直接回到 Sentinel。这样防止被注入的模型伪造审批（A）。
- **确定性 UI 不可让步的地方**：结构化批准卡和凭据安全存储（A）。
- **主动性的门槛要高**：默认档位对多数人合适，但可以通过对话调节强度（A）。

### 2.2 Hark Pro

**信息架构（A 级，来自 Using Hark 帮助页）**
```
Hark Pro
├─ Home —— 可自定义；Hark 把「及时信息」送到这里
│   ├─ Action Cards / Action Buttons —— 一张卡一个动作；点「Pay」「Cancel」这类词本身就会执行
│   │   （来源：邮件内容 + 对话中学到的信息）
│   └─ Panels —— Hark 生成的迷你应用（Strava 训练、Netflix × 烂番茄、ParentSquare 成绩……）
│       └─ 「Reply」→ 和 Panel 对话、重新设计它
├─ Chat —— 唯一的主线程；Handoff（云端电脑）在这里发生，小窗口实时显示浏览过程
├─ Projects —— 按主题拆分的独立线程，带文件
├─ （隐式）Specialties —— 自动记住的多步工作流
├─ （隐式）Scheduled Tasks —— 用对话创建的定时任务
├─ Settings → Profile → Delete Account；Settings → Send Feedback
└─ About → Contact Us
```
- 主动推送 vs 我发起：**分开放**。主动事项在 Home 卡片栈，我发起的事在 Chat（A）。Gizmodo 描述的 Web 版布局：首页左侧是主动卡片栈和 Panels，中间是叫作「composer」的输入框（A）。
- 记忆：**没有可视化的记忆页**的公开证据；删除方式是「让 Hark 忘掉」（A）。
- 连接器：叫作「Services」，包括 Google Workspace、Microsoft 365 等，另外可通过 MCP 接文件和外部数据库（A）。

**视觉系统**
- 背景是实时天空模拟，根据位置、风速、云量、颗粒物和时间渲染，日出日落与现实同步；追踪十几种实时信号并随机化，「never repeats」；Web 端使用 WebGL（A）。官方原话：「It's the second most beautiful sky you will ever see.」
- 卡片栈和层叠通知「looks almost like something Apple would design」（Gizmodo 主观评价，B）。
- 色值、字体、圆角：**没有公开资料**，不提供截图取色值。
- Liquid Glass：**没有公开资料**（C：设计负责人来自 Apple、背景是动态天空，半透明材质的可能性高，但未经证实）。

**核心界面逐屏**

| 屏 | 布局与控件 | 状态 | 证据 |
|---|---|---|---|
| Home | 卡片栈（审批、收据报销、航班值机、付款）+ Panels 网格 | 需要批准时，卡片本身就是批准（一个动词按钮） | A |
| Chat | 简短回复；需要时插入图表和多媒体；Handoff 小窗显示浏览过程 | 执行中可以看到浏览器；Gizmodo 演示中点麦当劳外卖花了「几分钟」，最后一步由用户确认付款 | A |
| Projects | 主题线程 + 文件 | — | A |
| Panels | 迷你应用，可以 Reply 追问或重新设计 | — | A |

**写作口吻（官方原文摘录）**
1. 「Hark speaks in short bursts rather than long novels」
2. 「There's no reason to bury someone in more information than they will read」
3. 「Notifications give you problems. Action Buttons give you solutions.」
4. 「Hark won't pile up all of this at once in your chat; it will pace these steps out so they arrive at just the right time.」
5. 「Hark will always ask the least of you possible to do the most for you that it can.」
6. 「No juggling "agents," "tokens," or other technical oddities required.」
7. 「Just ask Hark to forget a memory and it will.」
8. 「Language comes to life as instant utility.」
9. 「Hark is designed to avoid parasocial behavior. It is not built to be a bestie, romantic partner, or a psychologist.」
10. 「Even we can't see inside Secured by Hark.」

**设计判断**
- **反陪伴化**：明确不做恋人或心理咨询角色，极端情况下引导用户去联系真人（A）。这和 Muse「自建头像、起名字」的拟人路线相反。
- **可见的浏览器**：Chowdhury 说，展示 Agent 怎么浏览网页是为了建立信任（A）。
- **端到端完成**：尽量不中途把事情丢回给用户（A，TechCrunch）。

### 2.3 并排对比

| 维度 | Muse | Hark Pro | 适合谁 |
|---|---|---|---|
| 主动性呈现 | 混在主聊天里，用气泡分隔；Ideas 单独一个标签；强度可以口头调节 | 独立的 Home 卡片栈，一张卡一个动词；步骤分批推送 | Muse 适合「把它当人聊」的用户；Hark 适合「扫一眼就点」的用户 |
| 批准流 | 客户端原生对话框，由 Sentinel 签发；五种授权范围；结账每次都要批准 | 卡片按钮即批准；默认发邮件和花钱前先问（B） | Muse 适合要细粒度权限的谨慎用户；Hark 适合追求低摩擦的用户 |
| 记忆可见性 | 记忆文件可读、可编辑、可下载 | 只能口头「forget」，没有公开的记忆浏览页 | Muse 明显更透明 |
| 任务进度 | 头像状态摘要 + 活动日志 + Goals 计划 | Chat 内 Handoff 小窗实时浏览；Projects 承载长期任务 | Muse 适合多个长期目标；Hark 适合单次网页事务 |

**对 Com! 的判断**：主动性学 Hark，独立「在办」页加动词按钮卡；批准与记忆学 Muse，原生确定性批准卡加可编辑记忆文件；进度学 Muse 的「头像下方一行摘要」，正好对应你的手绘角色。

---

## 3. Agent 运行逻辑与实现方式（证据等级：A 官方直接可见 / B 间接推断 / C 行业推测）

**本节摘要**
1. Muse 的架构公开程度很高：每用户一台 Linux VM，systemd-nspawn 运行舱加宿主侧安全服务，Sentinel 是唯一的放行权威，凭据用替身 token，eBPF 做「污点出口」跟踪（全部 A）。
2. Hark 公开的是「功能」而不是「架构」：Handoff 自研 RL 模型、每个请求一台虚拟电脑、加密保险库在页面上才解 token。模型供应商、存储位置、同步协议都没有披露。
3. 两家都把「主动性」交给后台定时 + 事件触发，再做「值不值得提」的评估。具体阈值、每日上限都**没有公开资料**。
4. 成本侧：Muse 免费档的周额度很大（每周 1 亿 token，出自 Zuckerberg 的 X 帖子，帮助中心未列免费档额度，B）；Hark 声称 Handoff 的 token 价格不到前沿模型的 1/10（A，自报）。两家都靠「用量档」而不是「功能档」变现。

### 3.1 Muse

| 问题 | 结论 | 证据 |
|---|---|---|
| 模型 | Muse Spark 1.3（Meta 自研，闭源）；专门训练了零样本 CLI / skills 工具调用、长上下文、带注入意识的长轨迹指令遵循、多 Agent 协同 | A |
| 多模型路由 | 至少有：主模型 + 浏览器专用子 Agent + hatch-safety 的独立分类器集合 + 多个注入检测分类器 + 邮件 OTP 过滤分类器 | A |
| 本地模型 | 没有；推理通过 VM 内受限代理发往外部推理基础设施 | A |
| 思考模式 | **没有公开资料** | — |
| 短期上下文截断 | **没有公开资料**；只说「can manage lots of context」 | A / — |
| 长期记忆 | 跨会话持久；会「reflecting on what matters」；TIME 报道称每晚分析当天对话（B）；以文件形式存在 VM 里，可查看、编辑、下载 | A / B |
| 向量库 | **没有公开资料**；持久状态在独立的 Postgres（A），是否用 pgvector 属于 C | A / C |
| 记忆写入 | 自动（从对话中学习），用户事后编辑或让它 forget | A |
| 连接器 | 邮件、日历、Instagram / Facebook、车、家居、支付、购物、餐饮、音乐、健身等；每个都与服务方合作接入 API，并写了 SKILL 文件；Muse 可以给有 API / CLI 的服务自写连接器 | A |
| OAuth / 凭据 | OAuth token 存在用户 VM 内的 hatch-authd，不放在 Meta 中心化设施；运行舱只看到替身 token，Sentinel 在网络边界即时替换成真凭据 | A |
| 读写分离 | 有；而且比 OAuth scope 更细，例如授予 Gmail 读权限时可以去掉访问设置的能力 | A |
| 邮件安全 | 邮件连接器用确定性过滤加分类器，剔除一次性验证码、密码重置链接和魔法登录链接 | A |
| 主动性引擎 | 按计划（cron）和相关事件继续推进；完成后台工作后评估是否值得呈现；强度可调；用户可以说「关掉 / 调低 / 调高」 | A |
| 安静时段 / 每日上限 / 去重 | **没有公开资料**；TIME 引用的提示词示例暗示会学习用户偏好的打扰时段（B） | — / B |
| 动作执行 | 发邮件、订票、填表、谈判、购物（Stripe Link 一次性卡，绑定商户、金额和有效期）、写代码建工具；9 月 23 日起可控制 macOS 应用（B） | A / B |
| 批准粒度 | Sentinel 对每次连接器调用做 allow / deny / ask；授权可选一次性 / 会话 / 任务 / 限时 / 永久；只读、已授权、明显低风险的动作不打扰；「污点出口」：读过用户数据的进程失去自动放行资格 | A |
| 失败 / 结果未知 / 撤销 | **没有公开资料**；VM 数据持续备份、可以恢复（A）；购物享有 Link 的退货和购买保障（A） | A / — |
| 编排 | 多 Agent：主 Agent + 子 Agent 群（swarm）+ 浏览器子 Agent + Sentinel；有 crons；会「edits itself」，自建工具和技能 | A |
| 长任务 | 在云端 VM 后台运行，关掉 App 后继续 | A |
| 端云 / 同步 | 瘦客户端（iOS、Android、Web）通过安全传输层**直连用户自己的 VM**；具体协议（WS / SSE）**没有公开资料** | A / — |
| 离线 / 多设备 | VM 是唯一的事实来源，所以多端天然一致（C）；离线能看什么没有公开资料 | C |
| 安全与隐私 | 运行舱的 root 映射为宿主上的非特权用户；seccomp 禁用 io_uring 等；服务间通信用带 SO_PEERCRED 的 Unix socket；浏览器子 Agent 只看无障碍树、不能执行 JS；Meta 员工访问受运营政策约束，但架构上**不能**阻止 Meta 访问，要等 Confidential VM（「later this year」）| A |
| 训练 | 默认用脱敏轨迹训练，可以一键退出 | A |

**Muse 架构图（文字版）**
```
[iOS/Android/Web 瘦客户端] —(安全传输层，直连，协议未公开)→
┌──────────── 用户专属 Muse Secure VM（Linux） ────────────┐
│ ┌ 运行舱 systemd-nspawn（不可信区）────────────┐          │
│ │ Hatch 守护进程（Agent 编排）·子 Agent 群·cron │          │
│ │ 工作区文件 / 记忆文件 · 连接器 CLI 薄壳       │          │
│ └───────────┬─────── Unix socket + SO_PEERCRED ┘          │
│   宿主侧：hatch-safety（分类器）│ privsep 连接器 worker     │
│          hatch-authd（凭据 + 替身 token）│ Postgres 状态   │
│          Sentinel（allow/deny/ask + L4/L7 出口 + 污点）    │
│          浏览器 CDP broker（Chromium，用户可观看 / 接管）  │
│          推理代理 / 遥测代理                               │
└───────────────┬──────────────────────────┬───────────────┘
        [Muse Spark 1.3 推理集群]     [第三方服务 API / Web / Stripe Link]
```
确认（A）：VM 内所有组件、Sentinel 的职责、凭据替身、直连。推测（C）：客户端协议、推理集群部署形态、记忆的具体存储格式。

### 3.2 Hark Pro

| 问题 | 结论 | 证据 |
|---|---|---|
| 模型 | 自研电脑操作模型 Handoff（RL 训练），在 Online-Mind2Web 上自称第一；声称平均比 GPT-5.4 高 8 分、比 Opus 4.8 高 2 分（自报，部分评测用自家 harness）。条款写明「built using AI models … provided by third parties」，说明对话层用的是第三方模型，但没有点名 | A（自报）/ B |
| 多模型路由 | 至少分成「对话模型（第三方）+ Handoff（自研）」两层 | B |
| 本地模型 | 没有证据 | — |
| 记忆 | 记住用户告诉它的和它学到的；建立「portrait of you」；口头 forget；没有可视化记忆页 | A |
| 训练 | 隐私政策称不用你的数据训练，并与 AI 供应商签了禁止训练的书面协议 | A / B |
| 连接器 | Services：Google Workspace、Microsoft 365、Slack 等，走 API；另外支持 MCP；其余网站一律走 Handoff 浏览器登录（「millions of websites」）；Google 数据遵循 Limited Use 政策 | A |
| 同步频率 | 订单追踪有「几分钟」延迟 → 轮询（B） | B |
| 主动性 | Action Cards 来自邮件内容和对话记忆；「pace these steps out」；例子：发现学生饭卡余额将尽，经授权后可以自动充值 | A |
| 安静时段 / 上限 | **没有公开资料** | — |
| 动作 | 订餐、买菜、订机票酒店、付账单、取消订阅、退货、发邮件、做网站 / 表格 / 幻灯片；暂不能打电话（Adcock：「We'll get there」，B） | A / B |
| 批准 | 「checks in with you before doing something that requires your approval」；Gizmodo 演示中最后由用户确认付款 | A |
| 编排 | 「Handoff juggles up to 6 browsers at the same time」；每个请求起一台带浏览器、文件系统、终端的虚拟电脑。另有媒体写「36 browsers」，与官方的 6 **冲突**，以官方为准 | A |
| 端云 | 瘦客户端 + 云端；同步协议**没有公开资料** | C |
| 安全 | Secured by Hark 保险库：卡号和密码加密存储、传输中也加密，只在目标页面上解 token；限制并审计员工访问账户 | A |

**Hark 架构图（文字版）**
```
[Web(WebGL 天空)/iOS/Android 瘦客户端：Home·Chat·Projects]
        ↕（协议未公开，C）
[Hark 云端编排：对话模型（第三方，B）·记忆·Specialties·Scheduled Tasks·Action Card 生成]
        ↕
[Handoff：每请求一台虚拟电脑（浏览器 / 文件系统 / 终端），最多 6 浏览器并行，A]
        ↕                         ↕
[Services API：Google/M365/Slack/MCP，A]  [Secured by Hark 保险库 → 目标页解 token，A]
```

### 3.3 商业与成本反推（全部为 C，除非另注）
- Muse：免费档每周 1 亿 token（出自 Zuckerberg 的 X 帖子「up to 100M tokens per week」，帮助中心未列免费档额度，B）≈ 每天 1400 万 token。按前沿模型的公开价格量级算，满额用户每天成本可能达到数美元，所以免费档的定位是「多数人用不满」（C）。控制成本的可能做法：子 Agent 用小模型、长上下文缓存、cron 合并批处理、分类器前置拦截（C）。Meta 官方说订阅档「help us cover the compute costs」（A，Axios 引述）。
- Hark：Handoff 的 token 价格「不到 1/10」（A，自报），说明他们的成本大头是浏览器操作步骤，所以用自研小而快的模型替代前沿模型（B）。免费档有用量上限，再加 credits 自动充值（A）。

---

## 4. 可直接借用的开源项目（查询日期 2026-10-10）

**本节摘要**
1. 你已经在用的 **Hermes Agent（MIT，约 25.2 万 star）** 本身就带记忆、技能、cron、MCP，是最贴合的编排底座。不要换框架，在它外面包一层 FastAPI 状态机就行。
2. 记忆首选 **Hindsight（MIT，2026-10-09 仓库页显示 44.6k star）**，有 retain / recall / reflect 和 Hermes 集成；备选 mem0（Apache-2.0）和 Graphiti（Apache-2.0）。
3. 连接器的最大风险是 **Garmin**：据 etweisberg/garmin-connect-mcp 的说明，2026 年 3 月 Garmin 改了认证，garth 和 python-garminconnect 一度失效。EWS 有多个基于 exchangelib 的 MCP server 可选。
4. 已经有人开源「Muse 复刻」：**CopilotKit/OpenMuse（MIT，alpha）**；nanoMuse 是 **GPL-3.0（🔴 传染）**。Hark 没有找到开源复刻。
5. **数据口径说明**：star 和更新日期来自 GitHub 页面摘录、组织仓库列表和 star-history 的检索快照（9 月下旬到 10 月 8 日），不是 10-10 当天逐页打开的值；「最近提交日期」大多只有组织页的「Updated」日期，可以作为近似。clone 前请自己再刷新一次。

### 4.1 个人 Agent 整体框架 / 编排（按贴合度排序）

| 项目 | Star / 更新 | License | 语言 | 对应 Muse / Hark 的部分 | 接入难度 | 坑与活跃度 |
|---|---|---|---|---|---|---|
| NousResearch/hermes-agent — https://github.com/NousResearch/hermes-agent | ≈252k；组织页显示 2026-10-08 更新 | MIT | Python 为主 | 主 Agent + 记忆 + 技能 + cron + MCP + 20 多个消息平台；对应 Muse 的 Hatch harness | **小**（你已在用） | Issues / PR 都在 5k+，版本迭代快，升级可能有破坏性变更；把 Hermes 当执行器，不要当状态的真相来源 |
| openclaw/openclaw — https://github.com/openclaw/openclaw | ≈391k | MIT（star-history 显示 NOASSERTION，以仓库页为准） | TypeScript | 「助手跑在你自己的设备上」；技能系统；模型和 harness 可插拔。Stark Insider 报道称 Muse 内部结构与它高度相似 | 中（Node 栈，和你的 Python 后端并行） | 安全公告多（仓库曾有 73 条 security advisories 的快照），默认权限要收紧 |
| CopilotKit/OpenMuse | ≈4.2k（指南转述） | MIT | 未核实 | 明确对标 Muse：常驻 Chromium、可选 Linux 工作区、Gmail / Calendar、iOS / Android / Web 端 | 中 | alpha 阶段；适合**参考 UI 和流程**，不适合直接依赖 |

### 4.2 记忆系统

| 项目 | Star / 更新 | License | 对应功能 | 难度 | 坑 |
|---|---|---|---|---|---|
| vectorize-io/hindsight — https://github.com/vectorize-io/hindsight | 44.6k star、5.9k fork、3,381 次提交（2026-10-09 仓库页；组织页曾显示 46,291，以仓库页为准）；组织页 2026-10-06 更新 | MIT | 区分 world facts / experiences / mental models；retain / recall / reflect，对应 Muse 的「reflecting on what matters」；已是 Hermes 的社区记忆 provider；内置 MCP 端点 `http://localhost:8888/mcp/{bank_id}/`；LLM 封装支持 Ollama / LM Studio | **小** | README 写明存储用「PostgreSQL + pgvector」（pg0 内嵌）；reflect 要调用 LLM，有成本 |
| mem0ai/mem0 — https://github.com/mem0ai/mem0 | ≈66.8k | Apache-2.0 | 事实抽取、更新、删除，多级记忆（用户 / 会话 / Agent） | 小 | README 自己写了：基准分数来自托管平台的专有优化，开源版只是「directionally similar」 |
| getzep/graphiti — https://github.com/getzep/graphiti | ≈31.4k；2026-10-02 | Apache-2.0 | 时间感知的知识图谱（事实有有效期），适合「日程 / 账单随时间变化」；有 MCP server | 中 | 需要自带图数据库（Neo4j / FalkorDB 等），对单机 SQLite 栈偏重 |
| （自写）Markdown 记忆文件 | — | — | 对应 Muse 的「可读可编辑记忆文件」 | 小 | 必须做：作为 UI 的「真相层」，向量 / 图只当索引 |

### 4.3 连接器（优先 MCP）

| 源 | 项目 | 状态 / License | 说明 | 难度 |
|---|---|---|---|---|
| EWS 工作邮箱 + 日历 | viartemev/outlook-ews-mcp | 2026-07-31 更新；Python + exchangelib；License **未核实** | 邮件、日历、联系人、附件、空闲忙碌；读和写工具分开标注 | 小 |
| EWS | azizmazrou/ews-mcp | v4.5 线；有 Docker 和 stdio；License 未核实 | 「explicitly gated」发送，和你的批准流天然契合 | 小 |
| Garmin | Taxuspt/garmin_mcp | MIT（mcp.so 转述）；README 提到 110+ 工具、python-garminconnect v0.3.2 | 一次性 `garmin-mcp-auth` 登录，不存邮箱密码 | 中 |
| Garmin | etweisberg/garmin-connect-mcp | License 未核实 | 用 Playwright 抓浏览器会话 cookie，绕过 2026 年 3 月的认证变更 | 中 |
| GitHub | github/github-mcp-server | MIT；约 33.4k | 官方维护 | 小 |
| Gmail / Google 日历 / CalDAV / Apple 日历 | 本次**未核实**具体仓库 | — | Apple 日历建议在 Mac 上用 EventKit 自写一个小服务（C）；Google 用官方 API | 中 |
| ezbookkeeping | 未找到现成 MCP（**没有公开资料**） | — | 用它的 REST API 自写 | 小 |

### 4.4 iOS 端

| 项目 | Star / License | 用途 | 难度 | 坑 |
|---|---|---|---|---|
| gonzalezreal/textual | ≈852 star（Swift Package Index），约 1 个月前活跃；License 未核实 | SwiftUI 富文本渲染引擎，是 MarkdownUI 的继任者 | 小 | 较新，API 可能变动 |
| gonzalezreal/swift-markdown-ui | ≈3.9k；MIT；**维护模式** | 成熟的 GFM 渲染 | 小 | 不再开发新功能；流式渲染需要自己做增量 |
| 语音转写 / Liquid Glass / 状态动效 | 本次**未检索核实**具体仓库 | 建议直接用系统 API：iOS 26 的 `glassEffect`、语音转写框架（C） | 小 | — |

### 4.5 主动性 / 调度 / 评估

| 项目 | 说明 | License |
|---|---|---|
| agronholm/apscheduler | 7.6k star、783 fork；3.11.3 于 6 月 28 日发布，master 很活跃；README 警告「The v4.0 series is provided as a pre-release… do NOT use this release in production!」，请锁定 3.x | MIT（GitHub 仓库页显示「MIT license」） |
| launchd（系统自带） | 负责拉起 FastAPI 和各类 watcher | 系统组件 |
| Hermes 内置 cron | 已有，直接复用 | MIT |
| ProactiveBench / Proactive Agent（arXiv:2410.12361，Yaxi Lu、Zhiyuan Liu、Maosong Sun 等，2024-10-16 提交，v3 为 2024-12-03） | 摘要原文：「a diverse dataset, ProactiveBench, containing 6,790 events… our fine-tuned model achieves an F1-Score of 66.47% in proactively offering assistance」；用户接受或拒绝 Agent 的提议，以此训练奖励模型。「233 条测试集」和「单独的误报率指标」在摘要中没有出现，需对照论文正文核实 | 仓库和 License 未核实 |
| ProAgentBench（arXiv:2602.04482） | 来自 500+ 小时工作会话的 2.8 万+ 真实事件；测试 30 秒到 10 分钟窗口内「什么时候该插话」 | 未核实 |

**「乱打扰」评估方法（自用，C）**：每张卡记录 `shown / acted / dismissed / snoozed / muted_source`。每周统计「打扰精度 = acted ÷ shown」和「漏报 = 事后用户手动处理、但系统没发卡的事件数」。目标是精度 ≥ 60%、每日推送 ≤ 3 条。

### 4.6 已有的复刻 / 拆解
- **CopilotKit/OpenMuse**（MIT，2026-09-22 发布，alpha），是开源的 Muse 替代品。
- **nanoMuse**（🔴 **GPL-3.0，传染性，不要直接拷代码**；论文 arXiv 2610.08699）：根据 Meta 公开资料和「一份生产提示词副本」重建 Muse 的设计，并逐条标注信息来源。泄露提示词这部分的可信度和合规性都存疑。
- **Stark Insider 拆解**：认为 Muse 内部由 Linux VM、MEMORY.md、Chromium、子 Agent、技能和 cron 组成，并转述 Nat Friedman 的说法：Muse 受 OpenClaw 启发（B）。
- **Hark**：**没有找到开源复刻或详细拆解**。00000star/hark-pro 只是同名的无关仓库；Rakazo、MausBot 是竞品营销页，不是拆解。

---

## 5. 落到 Com! 的手搓框架方案

**本节摘要**
1. 原则：Hermes 只负责「思考和执行」，FastAPI + SQLite 是**唯一的状态真相**。批准、验收、结果未知全部由确定性代码判定，不让 LLM 宣布完成。
2. 用一个「Policy Gate」（规则表 + allow / deny / ask）替代 Sentinel；凭据放 macOS Keychain，Agent 只拿替身句柄。
3. 主动性按「事件 → 规则过滤 → LLM 打分 → 合并 → 配额 → 发卡」处理：静默时段 22:30–07:30，每天原生推送 ≤ 3 条，在办卡 ≤ 8 张。
4. 三周路线：W1 跑通状态机和批准卡；W2 接入记忆和主动引擎；W3 完成 UI 复刻和评估。

### 5.1 分层蓝图

| 层 | 选型 | 一句话理由 |
|---|---|---|
| 客户端 | SwiftUI 自写，Markdown 用 Textual（或 swift-markdown-ui） | 批准卡、在办卡这类确定性 UI 必须原生，参考 Muse 的「non-negotiable」做法 |
| 同步 | SSE（服务器 → 手机）+ REST（手机 → 服务器）；每个事件带递增 `seq`，断线后按 `Last-Event-ID` 续传；APNs 只发「有新卡」的空推送 | 你已有 SSE；用 seq 续传解决离线补齐和多设备一致性 |
| 编排 | FastAPI 状态机 + Hermes（对话）+ Pi / Claude Code / Codex（工程任务） | Hermes 自带 cron 和 MCP，不用重复造 |
| 策略闸 | 自写 Policy Gate：`(connector, method, scope) → allow/deny/ask`；每个能力授权都有一次性 / 会话 / 任务 / 限时 / 永久五种范围 | 照搬 Muse 的授权模型，但用确定性代码实现，单用户不需要第二个 LLM |
| 记忆 | Hindsight（retain / recall / reflect）+ `memory/*.md` 可编辑文件作为真相层 | 可视、可改、可删，对应 Muse 的 Memory files |
| 连接器 | MCP：outlook-ews-mcp / ews-mcp、Taxuspt/garmin_mcp、github-mcp-server；ezbookkeeping 和 Apple 日历自写 | 统一工具面，凭据只放在 MCP 进程和 Keychain |
| 主动性引擎 | APScheduler（或 Hermes cron）+ 各源 watcher + 规则表 + 小模型打分 | 先规则后 LLM，控制成本，保证「事件有来源」 |

### 5.2 最小数据模型

```sql
source(id, kind['gmail','ews','gcal','apple_cal','ezbook','garmin','github','mac_session'],
       status['ok','degraded','down'], last_ok_at, last_error, cursor, poll_interval_s)

matter(id, title, source_id, external_ref, dedup_key UNIQUE, first_seen_at, last_event_at,
       state['open','snoozed','resolved','muted'], snooze_until, score, evidence_json)

proposal(id, matter_id, action_kind, action_payload_json, risk['read','reversible','irreversible'],
         grant_scope_options_json, state['pending','approved','rejected','expired'],
         decided_at, decided_grant_scope, expires_at)

task(id, matter_id NULL, proposal_id NULL, executor['hermes','pi','claude_code','codex','connector'],
     state[...见下], plan_json, result_json, verify_json, attempts, started_at, finished_at)

memory(id, kind['fact','preference','event'], text, source_ref, confidence,
       state['active','pending_confirm','forgotten'], file_path, created_at, updated_at)

card(id, matter_id, task_id NULL, kind['reply_needed','conflict','budget','task_done','source_down'],
     verb, shown_at, outcome['acted','dismissed','snoozed','muted'], push_sent BOOL)
```

**任务状态机与 UI 对应**
```
drafted → needs_approval ──approve──→ queued → running → awaiting_verification ──verify ok──→ done
              │reject→ cancelled            │            │verify fail→ failed（可重试）
              │expire→ expired              │            └ no signal / timeout → outcome_unknown
              └ (Policy=allow) 直接 → queued └ error→ failed
```
| 状态 | 「在办」页 UI | 规则 |
|---|---|---|
| needs_approval | 橙色批准卡：动作摘要 + 精确参数（收件人、金额）+「批准 / 拒绝」+ 授权范围选择器 | 批准只能从原生按钮走 REST，**不接受聊天里的「好的」** |
| running | 卡片显示执行器名和最近一行日志（对应 Muse 头像下的摘要）；顶栏角色进入「工作中」状态 | 角色动画只由 running 事件驱动 |
| awaiting_verification | 「执行完待验收」：附验证证据（测试结果、邮件 Message-ID、日历事件 ID）+「验收 / 打回」 | 有可验证证据才能自动验收；工程任务默认人工验收 |
| outcome_unknown | 灰色问号卡：「我不确定是否成功」+ 最后已知证据 +「去核对 / 重试 / 标记完成」 | 超时或连接器无回执时进入，**绝不自动标为 done** |
| failed | 红色卡：错误原文的一句话摘要 + 重试 | — |

### 5.3 主动性规则初版

**流水线**：事件进来 → ① 规则过滤（来源白名单、发件人、关键词、金额阈值）→ ② 生成 `dedup_key`（来源 + 外部 ID 或线程 ID + 类型）→ ③ 评分 → ④ 合并（同一 matter 30 分钟内的多个事件合成一张卡）→ ⑤ 配额与静默 → ⑥ 发卡（在办页）/ 原生推送。

**评分（0–100）** = 紧迫度 40（距截止时间：<2h=40，<24h=25，<72h=10）+ 重要度 30（人 / 金额 / 工作邮箱）+ 可行动性 20（有明确动词按钮 +20）+ 新颖度 10（与上次同类卡间隔 >24h），减去打扰惩罚（同来源 7 天内 dismissed 次数 × 10）。
- ≥ 70：发卡 + 原生推送（受每日上限约束）
- 40–69：只发在办卡，不推送
- < 40：只记账，进每日简报

**配额**：静默时段 22:30–07:30 不推送（≥ 90 且 2 小时内截止的除外）；每天原生推送 ≤ 3 条；在办页活跃卡 ≤ 8 张，超出时按分数挤掉最低的；同一 `dedup_key` 只发一次，状态变化（例如出现新回复）才重新开卡。

**5 个场景走一遍**
1. **新邮件要回**（EWS）：老板的邮件含问句，且收件人是本人。重要度 30 + 紧迫度 25（对方写了「今天」）+ 可行动性 20 + 新颖度 10 = 85 → 发卡「回复」，Hermes 预写草稿 → proposal（risk = irreversible）→ needs_approval → 批准后通过 ews-mcp 发送 → 用回执的 Message-ID 验收 → done。
2. **日程冲突**（Apple + Google + EWS 三个日历）：同一时段两个已接受的会议，提前 26 小时发现。紧迫度 10 + 重要度 30 + 可行动性 20 + 新颖度 10 = 70 → 推送「改期 / 拒绝其一」。改期涉及他人，必须批准。
3. **账单超支**（ezbookkeeping）：餐饮类月度预算用到 110%。规则直接命中，紧迫度 0 + 重要度 20 + 可行动性 0 + 新颖度 10 = 30 → 只进每日简报，不打扰。月预算到 150% 才升级为卡。
4. **任务跑完**（Codex / Claude Code）：running → 退出码 0 + 测试通过 → awaiting_verification 卡（不推送，等你打开在办页）；退出码 0 但没有测试结果 → outcome_unknown；进程消失 → outcome_unknown，30 分钟后仍无结果才推送。
5. **信源断了**（Garmin 认证失效）：连续 3 次拉取失败 → source.status = down → 「信源断了」卡，按钮「重新登录」。同一个源 24 小时只提醒一次。断源期间该源产生的主动卡全部暂停，避免基于旧数据打扰。

### 5.4 UI 复刻清单

| 参考 | Com! 对应页 | 新建组件 | 预计工时 |
|---|---|---|---|
| Muse 主聊天 + 气泡 | 对话 tab | `StreamingMessageView`（Textual 增量渲染）、多条连发队列、Side chat 入口 | 3 天 |
| Muse 头像状态摘要 | 顶栏手绘角色 | `AgentStatusStrip`：角色 + 一行「正在做」，点击打开活动日志 | 1.5 天 |
| Muse 活动日志 + 权限 | 角色详情 sheet | `ActivityLogList`、`GrantList`（可撤销） | 2 天 |
| Muse 批准卡 / Hark Action Button | 在办 tab | `ApprovalCard`（动词按钮 + 精确参数 + 授权范围 Picker）、`VerifyCard`、`UnknownOutcomeCard` | 3 天 |
| Hark Home 卡片栈 | 在办 tab 顶部 | `ProactiveCardStack`（滑动 = 稍后，长按 = 静音此来源） | 2 天 |
| Muse Goals / Hark Projects | 工作 tab | `MatterList`、`TaskTimeline` | 2.5 天 |
| Muse Memory files | 设置 → 记忆 | `MemoryFileEditor`（Markdown 编辑 + 「忘掉」）、pending_confirm 审核列表 | 2 天 |
| Com! 建议色（C，**不是**对方真实值） | 全局 | 背景 #F7F5F0 / 面 #FFFFFF / 强调 #E8642C（批准）/ 验收 #2F8F5B / 未知 #8A8F98；深色模式另配 | 0.5 天 |

### 5.5 三周路线图

| 周 | 可演示里程碑 |
|---|---|
| W1 | SQLite 模型 + 状态机 + Policy Gate；EWS 新邮件 → 卡 → 批准 → 发送 → Message-ID 验收，全链路跑通；SSE seq 续传 |
| W2 | Hindsight 接入 + Markdown 记忆文件双写；主动引擎（评分、合并、配额、静默）；日历冲突和账单两个场景；信源健康监测 |
| W3 | 在办 / 工作 / 记忆页按 5.4 完成复刻；Codex / Claude Code 任务的验收和结果未知流程；打扰日志和每周精度报表 |

**最先验证的三个风险假设**
1. **EWS 和 Garmin 能稳定拉取**（Garmin 3 月的认证变更是已知风险）：W1 第 1 天就先跑通认证。
2. **「打扰精度 ≥ 60%」能靠规则 + 小模型做到**：W2 结束时用一周的真实数据检验。
3. **Hermes 能被约束为「只提案不执行」**：所有写动作都必须经过 Policy Gate，W1 用一次注入测试邮件验证。

### 5.6 明确不做的

| 功能 | 砍掉原因 |
|---|---|
| 每用户云端 VM / Confidential VM | 单用户、本地 Mac mini 就是你的「VM」，多租户隔离对你没有价值 |
| 独立 LLM 版 Sentinel | 用确定性规则表更便宜、更可审计；单用户场景下 LLM 判权反而多一个注入面 |
| 浏览器代购 / 支付钱包（Stripe Link、Handoff） | 成本高、易碎（Amazon 已封锁 Muse），且违反「凭据不出家门」 |
| Realtime Avatar 视频、WhatsApp 通道 | 和手绘角色定位重复；第三方通道会让数据出门 |
| Hark Panels（生成式迷你应用） | 维护成本高；先用固定的「工作」tab 卡片，后面再看 |

---

## 我最该先看的 10 个链接
1. https://introducing.muse.ai/ —— Muse 设计决策原文
2. https://security.muse.ai/ —— Muse 架构、Sentinel、批准粒度
3. https://hark.com/using-hark —— Hark 信息架构、Action Buttons、Panels、Specialties
4. https://hark.com/articles/introducing-hark-pro —— Hark 设计口吻与 7 段功能视频
5. https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/ —— Muse 发布稿与 5 段视频
6. https://www.youtube.com/watch?v=wHn0hTjvFoo —— Muse Product Design Lead 走查（逐帧取色、确认 Tab 结构就看它）
7. https://gizmodo.com/hark-pro-ai-ui-2000822253 —— Hark 实际演示观感与首页布局
8. https://hark.com/articles/introducing-hark-handoff —— Handoff 模型、基准、成本
9. https://arxiv.org/abs/2410.12361 —— ProactiveBench：评估「该不该打扰」
10. https://github.com/vectorize-io/hindsight —— 记忆层首选

## 我最该先 clone 的 3 个仓库
1. **vectorize-io/hindsight**（MIT）：记忆层，直接挂到 Hermes。
2. **viartemev/outlook-ews-mcp**（License 待确认）或 **azizmazrou/ews-mcp**：工作邮箱是最高价值的主动性信源。
3. **Taxuspt/garmin_mcp**（MIT）：先验证 Garmin 认证这个最大的连接器风险。

---

## Caveats
- Hark 的 Handoff 基准成绩是自报，部分评测使用自家 harness；Muse Spark 的「接近 SOTA」也是自报。
- 没有逐帧看视频，也没有截图取色；凡是写「没有公开资料」的地方，都请以你自己装机实测为准。
- 开源项目数据来自 9 月下旬到 10 月 8 日的检索快照，clone 前请到 GitHub 页面复核 star、最近提交和 License，特别是标注「未核实」的 License。

---

## 对照 Com! 现状（Claude 核对，2026-10-10，非原报告内容）

核对依据：会话工作台 backend 代码、mini 上 `/personal/connectors` 与 `/personal/tasks` 的实时数据、mini 的 `~/.hermes/hermes-agent`。

### 报告建议里 Com! 已经有的

| 报告建议 | Com! 现状 | 位置 |
|---|---|---|
| Hermes Agent 当编排底座 | mini 跑的就是 NousResearch Hermes Agent 0.20.0，Com 通过 Hermes Runs 调用 | `backend/hermes_runtime.py`，mini `~/.hermes/hermes-agent` |
| 「LLM 的话不算授权」 | 已是原则：派活批准必须带 `explicit_authorization`，取消必须引用真实用户消息原文 | `backend/policy.py`、`app.py` approve / cancel |
| 静默时段 + 每日上限 + 强度档 | 已有：quiet_start/quiet_end，强度 quiet/balanced/active 对应每天 0/2/4 条主动观察，按 key 去重 | `backend/agency.py` `publish_observation` |
| 可编辑记忆 | 记忆有版本、分类、归档、纠正；共享知识以 Markdown 只读接入 | `backend/memory_catalog.py`、iOS `MemoryView` |
| 结果未知不当完成 | 任务有 unknown / execution_finished / verify / merge，验收需证据 | `backend/tasks.py`、iOS `TaskDetailView` |
| EWS 工作邮箱 | 已用 exchangelib 直连，不需要 EWS MCP；10-10 实测 connected，读到 93 封 | `backend/personal_hub.py` `ews_sync` |
| Hindsight 记忆 | 已部署在 MBP（launchd 常驻 8888，bank eddie-main），但还没接进 Com 后端 | Claude memory `project_hindsight_deploy` |

### 真缺口（按价值排序）

1. **「待验收」堆积，没有自动验收**。mini 实测 21 个任务停在 execution_finished：codex 9、pi 5、hermes 5、claude 2；全部没有 acceptance_criteria，其中 6 个 verification 已 passed 仍没人点验收。这就是 Eddie 说的「等你决定里一堆废弃项」。10-10 加的「超过 7 天折叠归档」只覆盖其中 3 个。报告 5.2 的规则「有可验证证据才能自动验收」正好对症：verification_status=passed 且无验收条件的，应自动收尾进「已结束」。
2. **主动性没有评分和合并**。`proactive.py` 里没有 score / dedup 字段；事项卡按来源和截止时间排序，所有新邮件都可能成卡。报告 5.3 的「紧迫 40 + 重要 30 + 可行动 20 + 新颖 10 − 打扰惩罚」可以直接落在 `personal_hub.briefing()` 的排序之前。
3. **没有打扰账本**。agency 的 later / handled / mute 已经记反馈，但没统计「shown → acted」。补一张 card_outcome 表，每周出打扰精度，才能知道调规则有没有用。
4. **批准没有授权范围**。现在每次派活都单次批准；Muse 的一次性 / 会话 / 任务 / 限时 / 永久五档在 Com 里没有。注意 10-03 Eddie 已撤销 Com 的只读限制（`operation_policy.py` full-access），授权范围要重新设计在「派活提案」这一层，不是执行沙箱层。
5. **活动日志入口**。点顶栏角色目前是菜单；Muse 是「点头像看活动日志和已授权权限」。可以把「看她的工作台」升级为活动日志。
6. **Garmin 仍是 needs_connection**。和报告「2026 年 3 月认证变更」的风险一致，值得按报告建议先试 Taxuspt/garmin_mcp 的一次性登录。

### 报告里不适用或要修正的
- 报告第 4.3 节建议给 EWS 上 MCP server：Com 已直连，不必再加一层。
- 报告第 5.4 节建议色是橙色强调，和 10-10 定下的青柠版冲突，忽略。
- 报告第 1 节、第 3 节的产品事实（发布日、定价、架构细节）Claude 没有独立联网核实。
