# Com! iOS · 回到青柠版 + Liquid Glass，顺手把「等你决定」理顺（2026-10-10，Claude）

> 起因：Eddie 看完方向 C「纸感便签」真机后提了四条（Dock 不统一、等你决定看不懂且卡、菜单没对准人物、下拉没动画），并决定 UI 退回上一版青柠色，只在它的基础上统一、做现代。功能层授权大改。
> 上一版落地记录：`docs/COM_IOS_REDESIGN_C_IMPL_20261009.md`（方向 C 的 IA、角色和待处理模型这次都保留，换掉的只是视觉层和几处交互）。

## 一句话

视觉层整体换回 git HEAD 的「层级」设计系统（青柠 accent、白卡 22pt 圆角、系统圆体标题），所有浮在内容上的控件改成 iOS 26 Liquid Glass；三 tab + 顶栏角色 + 统一待处理模型保留。功能层把「等你决定」收成一个地方（在办），每一条都能左划，旧任务折叠一键归档，后端新增归档接口。

## 1. 四条反馈怎么落的

| 反馈 | 根因 | 做法 |
|---|---|---|
| Dock 在 Com 页是固定条，其他页是玻璃 | 聊天页输入区压在 Dock 上面，没有内容从 Dock 下面滑过，玻璃看起来像实心条；而且 Dock + 输入区占了两行 | Com 页不再单独放 Dock：迷你 Dock（三个图标的玻璃胶囊）并进输入区那一行左侧，打字 / 录音时自动让位；在办 / 工作保留整条玻璃 Dock，内容从下面滑过 |
| 等你决定：Hermes/Pi/Claude/Codex 那几条不能左划，最下面几条能 | 原来只有事项（matter）允许「划掉」，任务和派活故意禁掉了 | 每一种都能左划：任务→归档、派活→先别、目标→暂停、事项→划掉（留到明天）。标签在划出时显示 |
| 等你决定里一堆废弃项 | 后端里停在 waiting/unknown/paused/待验收 的旧任务没有出口，只能停止或验收 | 超过 7 天没动静的任务折成一行「N 件超过一周的旧任务」，一键「全部归档」；后端新增 `POST /personal/tasks/{id}/dismiss`：记一笔 `dismissed` 事件并置为 cancelled，不联系工作器，之后在「已结束」里能 resume 恢复 |
| 等你决定不知道干嘛用 | 同一份东西出现在 5 个地方（流里便签、右上待处理清单、在办「等我决定」、顶栏数字、Dock 红点） | 砍掉右上「待处理清单」sheet；**在办**是唯一完整清单，流里只放最近 4 组，溢出时一句「都在在办里」跳过去；Dock 徽标只数真要你拍板的（派活 + 任务），不数事项 |
| 等你决定卡 | 纸底是每帧画几千个点的 Canvas，加上 `pendingItems` 是计算属性，每次读都重新解析 JSON；清单 sheet 里又套了一层 List | 纸底删掉；待处理列表改成 `flowItems` 存储属性，只在相关接口数据变化时重算一次；sheet 删掉 |
| 点人物菜单出现在左边 | 自绘弹层固定锚在左上角，人物走到右边时就对不上 | 改用系统 `.popover` + `presentationCompactAdaptation(.popover)`，锚点 = 她此刻站的矩形（`CharacterStrip.figureFrame`），箭头永远指着她 |
| 下拉没动画、只是淡入 | 原来拖动结束才切换状态，用 `.move(edge:)` 过渡 | 舞台面板常驻根视图顶层，`stageProgress` 0…1 跟手：顶栏像一滴玻璃被拉长（`glassEffect` + 底部圆角随进度变化），场景在里面放大淡入；松手按预测落点开合；拉开后在面板上往上推同样跟手，过头有橡皮筋 |

## 2. 视觉系统（`Views/DesignSystem.swift`）

- Token 回到 HEAD：accent 青柠 `#D1F061`（只做填充）、accentText `#4C6600`、background `#F4F3EF`/黑、surface 白/`#1C1C1E`、fill `#F0EEE9`；状态色 success/warning/danger/info 四档。
- 字阶：largeTitle/title/section 用 SF Rounded 粗体，正文 body 17 / callout 16 / footnote 13 系统字。宋体、印章、虚线、纸胶带、倾斜全部移除；Noto Serif 字体文件移到 `_archive/ios-removed-20261010/Fonts/`，Info.plist 的 UIAppFonts 删掉（包体小 4.6 MB）。
- 旧便签 API 保留名字但换了样子，页面不用改：`Stamp` → 胶囊状态、`noteSurface` → 22pt 白卡、`DashedRule` → 0.5pt 细线、`LinedText` → 左侧青柠线的引用块、`Card(.highlighted(.accent))` → 青柠描边。
- Liquid Glass 只给浮动控件：Dock、聊天迷你 Dock、顶栏搜索钮、回到最新、输入区胶囊（`composerSurface`）、下拉舞台面板。内容卡片保持不透明。

## 3. 结构变化

| 位置 | 现在 | 文件 |
|---|---|---|
| 顶栏 | 角色条（点开 popover 菜单、按住下拉）+ 右侧：Com/在办 玻璃搜索钮，工作 青柠「新建」 | `Chrome.swift` `ComTopBar` |
| 聊天底部 | 一行：`ChatTabPill`（三图标玻璃胶囊，在办带数字徽标）+ 输入区；聚焦或录音时胶囊收起 | `ChatView.swift`, `Chrome.swift` |
| 在办 | 筛选 chips 常驻；等我决定（全部待处理 + 旧任务折叠块 + 全部稍后）/ 正在跑 / 目标 / 已结束（含归档）/ 定时 | `TasksView.swift` `DoingView` |
| 下拉舞台 | 场景 + 一行实情 chips：等你 N / 在跑 N / 信源状态 / 看回复，各自能跳过去 | `Chrome.swift` `StagePanel` |
| 删除 | `InboxSheet`、`MenuPopover`、`StageOverlay`、`showInbox`、`showDoingFilter`、纸底 `PaperBackground` | — |

## 4. 后端

- `backend/app.py` 新增 `POST /personal/tasks/{task_id}/dismiss`：只接受 waiting / unknown / paused / execution_finished / approval_required；待验收的直接置 cancelled，其余走 `task_store.finish(..., 'cancelled', '在手机上归档；未联系工作器。')`；完成后同步任务卡片。在跑的任务返回 4xx，必须先停止。
- 测试 `tests/test_api.py::test_task_dismiss_archives_waiting_task_without_touching_worker`（monkeypatch 掉 runtime.cancel_task/stop，确保不碰工作器）。mini 上 `test_api.py + test_personal.py` 25 passed；服务已 kickstart，/health 200。

## 5. 验证

- 模拟器 iPhone 17 Pro（iOS 26.3）编译通过；截图核对：流、在办、工作、聊天底部一行、旧任务折叠块。
- UI 测试：`testInboxListsEveryDecision` 改成 `testDoingListsEveryDecisionAndArchivesTasks`（在办 等我决定 · 3 → 全部稍后 → · 1 → 左划任务 → · 0 → 一键归档旧任务 → 已结束里都在）。验收数据加了一条远古 `unknown` 任务 `task-old`，其余任务时间戳改成「现在」附近，否则全部会被判成旧任务。
- 结果见本文末尾「测试结果」。

## 6. 产品层的几个判断（供 Eddie 复核）

1. **「等你决定」只有一个家**：在办。流里的卡片是「它主动来找你」的入口，不是清单；数字徽标只数真要拍板的。
2. **任务有了退出口**：以前一个 waiting 任务要么回应要么停止，停止会去联系工作器；现在「归档」就是「我知道了，不作数」，可恢复。
3. **舞台从装饰变成仪表**：拉下来除了看她干活，还有等你 / 在跑 / 信源三格数字直达。
4. 没做、值得下一步做的：后端「回复草稿」字段（事项卡的草稿现在还是 next_step）；聊天页长按消息「交给电脑做」直接起派活；在办里按来源分组（邮件 / 日历 / 派活）。

## 测试结果

（见文末追加）

---

## 第二轮（10-10 上午）：「下一步」页 + 在办清场 + Dock 回到底部

依据：另一个 agent 的调研报告 `work/产品调研/Muse与HarkPro/Muse与HarkPro深度调研与Com落地报告.md`（§5.2 状态→UI 映射、§5.3 主动性流水线、Muse Ideas「I can… + 凭什么」）。

| 改动 | 做法 | 文件 |
|---|---|---|
| 聊天底部卡片消不掉 | 聊天时间线里的「今天」卡片块整个移除；账本、信源断了挪到「下一步」 | `ChatView.swift`、`FlowCards.swift` |
| Dock 回到最下面 | 删掉输入区左侧的迷你 Dock；四个 tab 共用一条玻璃 `ComDock`，聊天页打字时让位 | `RootView.swift`、`Chrome.swift` |
| 功能按键材质统一 | 顶栏右侧全部 `GlassIconButton`（搜索 / 重新整理 / 新建）；筛选 chips 改成玻璃，选中项青柠染色 | `Chrome.swift`、`DesignSystem.swift` |
| 在办清场 | mini 上 16 个卡死的测试/验收任务全部归档（可在「已结束」恢复）；在办只收派活待批准和停下来等你的任务，手动会话的「回合结束」不再算待验收；邮件日程事项不再混进来 | `FlowCards.swift`，mini 数据 |
| 新页「下一步」 | 第 2 个 tab。后端 `next_steps.py` 白天 8–23 点每小时主动整理一次（也可顶栏按钮 / 下拉立刻整理）：收拢 3 天内邮件（滤掉验证码、广告）、48 小时内日程、项目下一步、近两天任务、本月账本、目标 → Hermes 归纳 3–8 条建议，每条必须引用真实资料，引用不上就丢；模型失败退回规则。按「现在 / 今天 / 这周」分组；交给 Com（作为一条消息发给主对话）/ 已经做了 / 不用（7 天内不再提）；底部统计这周提了几件、做了几件、划掉几件 | `backend/next_steps.py`、`app.py` `/personal/next*`、`ios/Com/Views/NextView.swift` |

验证：mini 后端 29 passed（含 `tests/test_next_steps.py` 4 条）；第一轮真实整理 8 条建议全部引用真实邮件和日程（AI 德州扑克报名截止、给百度发信息、劳务报酬驳回、Today AI 订阅、搜狐待审批、楚骊材料、攀岩物料、报销截止）。模拟器 UI 测试 18 条：17 条一次通过，`testCancelledVoiceNeverSendsLateTranscript` 首轮失败、单独重跑两次都通过（语音类已知抖动）。真机未装：iPhone Air 当时未连接（devicectl 显示 unavailable）。

未做（报告里的其余项）：审批授权范围五档、Huey 持久队列、流式 Markdown、MEMORY.md 文件真相层、通知四闸门的完整打分与顺延。

---

## 第三轮（10-10 下午）：依据袋动效

参考：x.com/uiux_hamad/status/2108613525744885767（Hamad Tanveer「Just Playing with Motion」，2 秒，「Documents · 2 files」文件袋，悬停时两张纸错开、带倾角从袋口弹出）。

- 落点：「下一步」卡片的「依据 · N 份」改成依据袋（`NextView.swift` `EvidencePocket`，一个 ButtonStyle）。按住时纸片探出袋口；点一下纸片停在外面，下面展开依据列表；再点收回。纸片标题就是真实依据（邮件 / 日程 / 项目…），最多三张。
- 参数：前纸 -4° 抽出 42pt，后纸 +5° 抽出 54pt、晚 0.06s，第三张 +9°；弹出 spring(0.42, 0.58) 带回弹，收回 spring(0.32, 0.9) 反序；按下袋子缩到 0.985 并轻触感。减弱动态效果时只做平移淡入。
- 顺手修：依据列表 ForEach 用 RemoteRow 的 id，依据没有 id 字段，多条依据只显示第一条重复 N 次；改成按位置区分。
- 验证：模拟器录屏逐帧看弹出过程；UI 测试 18/18 通过。真机安装时 iPhone Air 显示 unavailable，未装。

## 第四轮（10-10 下午）：底部 Dock 改成「撑开的胶囊」

参考：x.com/nitishkmrk/status/2090423248307782069（Nitish Khagwal「expanding tab item interaction」，10 秒）。

- 样子：四颗独立的玻璃胶囊，没选中的只是 48pt 圆钮（黑色图标），选中的撑开露出图标 + 名字，染成本页颜色：Com 青柠深色、下一步紫、在办蓝、工作橙。
- 动效：宽度 spring(0.46, 0.66) 带回弹；名字用 blurReplace 从模糊淡入（出去的模糊淡出）并从左边放大；图标只变颜色；撑开后 0.22s 一道高光从左到右扫过名字（`ShineOnce`）；按下整颗缩到 0.92；切页触感改由 Dock 的 sensoryFeedback 发一次。减弱动态效果时只淡入淡出、不扫光。
- 结构修正：Dock 原来放在每个 tab 的页面里，TabView 切页时旧 Dock 和新 Dock 交叉淡化，任何 Dock 动画都看不到。现在 Dock 只有一条，挂在 TabView 外层（`RootView` overlay），页面底部留 `ComDock.height` 的空白。
- 两个坑：① 玻璃不包 GlassEffectContainer，否则徽标会被压到玻璃下面；② 图标不能放在 glassEffect 里面（包括 interactive 和普通），按下时图标会被玻璃高光吃掉、闪没几帧；现在玻璃只当底（`background { Color.clear.glassEffect }`），按压缩放用自己的 `DockPress`。
- 验证：模拟器录屏逐帧核对三次切页；UI 测试 18/18 通过。真机未装（iPhone Air unavailable）。

## 第五轮（10-10 傍晚）：下一步去重、记忆文件夹、工作页改聊天式

**1. 「下一步」点了「已经做了」过一会儿又冒出来**
- 根因：卡片按标题哈希去重。模型每小时重新归纳一次，同一件事换个说法就是新卡。mini 上实录：「回复攀岩活动物料设计需求」14:05 点了完成，14:14 冒出「推进攀岩活动物料设计」，17:25 又冒出「回崔梦宇攀岩物料需求」，三张卡引用的是同一封邮件。
- 修法（`backend/next_steps.py`）：
  - 改成按依据去重。7 天内划掉、做完或交给 Com 的建议，它们的依据记为「已处理」。新建议的依据全部落在已处理范围内，就不再出。
  - 依据怎么算同一个：邮件和日程看 matter id；项目看会话加上当前那一步进展的指纹。mini 和 MBP 同步的同一段会话算一份；进展真的往前走了，才会再提。
  - 喂给模型的 `recent_dismissed` 改成 `recent_handled`，把做完和交出去的也带上，并明确「换个说法也不要再提」。
  - 新建议只要带了一份没处理过的依据，照常出现。
- 验证：
  - 新增 3 条测试：换标题不复现、交出去的告诉模型且新依据照出、项目进展变了才再提。`tests/test_next_steps.py` 8 passed。
  - mini 重启后手动整理一轮，5 条建议里没有任何已处理过的旧事。
- 取舍：一件事做完，同一封邮件引出的另一件事 7 天内也不会再提，比如完成「补麻城报销 PR 号」后，「收拢 10 月报销单据」也被拦下。宁可少提，不重复打扰。

**2. 记忆按文件夹分类**
- 后端（`memory_catalog.py`、`app.py` `/personal/memory`）：
  - 新增 7 个文件夹：关于我、工作、创作、技能、设备、项目、生活。
  - 每条记忆带上 `folder`、纯文本 `preview`（去掉 `**`、反引号和列表记号）。对话里记住的事补一个 `title`（取第一句）。
  - 原来的 `category` 仍是写入校验口径，没动。
- 手机：
  - 首页是两列文件夹卡，每张有页签色条、条数和最近一条，下面是「最近更新」5 条，再下面是搜索。
  - 点文件夹用 zoom 转场推进明细；文件夹里可以筛「对话中记住 / 共享知识」。
  - 再点一条推进详情，不再在 sheet 上叠 sheet。详情顶部显示文件夹和来源两枚标签；对话记忆可展开「你当时说的」原话。
  - 旧后端没有 folder 字段时，客户端按 category 兜底。
- 真实数据分布：设备 7、技能 6、项目 4、创作 4、工作 3、生活 3、关于我 3。

**3. 工作页改成聊天式 + 两级分区**
- 分区：
  - 第一级是电脑。Mac mini 标「可派活」，MacBook 标「只读同步」，各带在线点和在跑数。
  - 第二级是 Agent 胶囊：全部、Hermes、Pi、Claude、Codex，带条数，有进行中的会亮绿点。最右边的「项目」打开原来的项目看板（改成 sheet）。
- 对话流：
  - 开头像一条来自该分区的消息：头像、对话数、进行中和未收尾数，下面是 3 件可以接着做的事。
  - 再往下是按「今天 / 昨天 / 这一周 / 更早」分组的对话列表，每页 40 段，可以继续展开。
  - 数据是两路合并：看板里两台机的进展，加上 mini 上能续接的会话，同一段只出现一次。
  - 命令回显类的标题（`<local-command-caveat>`）换成摘要或项目名。
- 打开方式：能续接的对话打开聊天详情。只有进展快照的（MacBook 上的 Pi 和 Codex）打开只读依据，行尾标「只读」。
- 输入框：
  - 左边头像就是派给谁，可以换；右边齿轮进完整的派活页，选目录和模型。
  - 在 MacBook 分区，输入框上方说明「由 Mac mini 上的 X 执行」。
  - 打字时 Dock 让位，和聊天页一样（`SectionTab.typing`）。
- 性能：真实数据有 174 个项目，原来的看板首屏不是懒加载，模拟器白屏 4 秒以上。现在对话流和看板都改成 `LazyVStack`。

**4. 其他二级页**
- 记忆、设置、数据连接、搜索与成果改成大标题，滚动时收进导航栏。
- 搜索页没有成果时显示空状态；分享收件箱为空时显示怎么用。

**验收辅助（仅 DEBUG + `--ui-testing`）**：
- `COM_FIXTURE_DIR` 读后端真实返回的 memory、sessions、projects JSON，按真实数据量看排版。
- `COM_PREVIEW_SHEET` 直接打开某个二级页，可选 memory、settings、search、finance、connectors、share、task。
