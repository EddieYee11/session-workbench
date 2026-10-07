# Com 按需上下文与 iOS 性能优化

2026 年 10 月 7 日。后端已在 Mac mini 加载，iOS 构建 2026100706 已安装到 iPhone 17 Pro。704 的跳动修复已由用户确认；706 的滑动顺畅度、回底动画与自动语音发送等待真机手持验收。当前实际主 Agent 仍为 Hermes，主模型仍是 `opencode-go/deepseek-v4.1-flash`，原有 Full Access 和业务授权保持有效。

主聊天现在只携带短运行契约、有限近期对话和在途任务索引。需要旧事实、完整历史或复杂操作规则时，由模型主动取用。原始聊天和 Markdown 文件保留，不通过删除历史实现减负。

## 本次追加修改（构建 705–706）

以当前真实 Hermes 后端为准，没有改用 Pi，也没有把旧 commit 的 Pi 配置照搬到在线环境。新增 `context_builder.py` 作为主对话的唯一工作集拼装入口；用户原话进入原生 input，本轮关联放在 instructions 侧。后续每轮仍只用 Com 原始近期记录覆盖原生累积历史，历史及原始资料不删除。重试身份绑定原话和真实来源，刷新中的任务索引不会导致同一请求身份冲突；原始 working set 在受理前冻结。用户原话不截断，简单轮次预算以实际 provider prompt tokens 核验。

`TaskStore.context_index()` 只读任务行，不加载每个任务的所有事件、补充与原文；每轮最多 5 个活跃索引，包含 ID、标题、状态和一句 next。明确回复/补充某个唯一任务时才提供该任务一份有预算的 brief；audit 保留数据库，完整详情通过 task_status 读取。关联事项只保留身份及短索引。

`message_router.py` 将路由结果、分类耗时、首段文字及总耗时、prompt 字符数记入独立 SQLite；不会调用另一轮分类模型。L0 覆盖明确记账、最近账单、提醒列表、今明两天日程、格式完整的绝对时间提醒、明确单链接收藏；全部复用 BusinessTools 的业务实现和原 request ID 的幂等回执。混合、引用、否定、缺参数和第三人称消费回退 Hermes。L1/L2/L3 是 Hermes 的分路建议，L3 仍由已有 task_submit 持久派工服务执行，不凭关键词猜工作目录或直接操作项目。

简单问候沿现有 flash 模型请求关闭推理，复杂工作保持当前运行时配置。真实供应端仍报告少量 reasoning tokens，不能宣称供应端已完全关闭推理。常用工具发现仍复用已部署的 Hermes tool_search 延迟 schema（初始 8 个工具），未另建一套全工具激活机制。后台事件保留独立 Hermes 运行及任务索引；前台不共享其 run_id 和队列。

按需记忆的语义等待降至 1.5 秒，返回最多 5 个片段、正文总预算 1500 字；自动召回仍为零。Mac mini 实测“攀岩”召回 1.506 秒，4 个当前 Markdown 片段，共 1316 字；语义超时明确标记 time_budget_exceeded，不当成没有记忆。

705 对 iOS 的修改：首段从 60 条降至 30 条完整布局的消息；可见性跟踪不再作为整张聊天页的状态更新；未变化的消息使用等值渲染，保持已解决的滚动位置稳定。开启 ProMotion 帧率支持，滑动和动画期间请求设备支持的最高回调频率；停止运动即停止采样。CADisplayLink 的统计只含主线程回调频率、长间隔及低电量状态，不包含聊天内容，也不等于 GPU 呈现 FPS。

回到最新使用 0.48 秒 easeInOut 缓入缓出动画；系统开启减少动态效果时仍直接定位。完成录音后显示文字揭示动画，再自动进入同一文本 outbox，不再显示编辑确认框；请求 ID 绑定 capture ID，进入持久 outbox 后移除录音，未知送达先查回执。706 补修了上一条文字正在送达时仍可完成录音并独立排队发送的情况，新增该路径 UI 验证通过。保留已有文字草稿，取消录音阻止迟到的识别结果发送，转写失败保留录音。录音入口同时扩大至 44 点并明确命中区域，修复测试中暴露的偶发点击不进入录音。

| 追加验收 | 结果 |
| --- | --- |
| 后端全量 | 519 项通过、3 项跳过；旧 Node 22 的原生 TS 导入检查在 Node 25 复验通过 |
| 最终受影响检查 | 49 项通过；URL 尾部 `?` 不被收藏路由改写的检查另通过 |
| iOS 核心 | 3 项通过 |
| iOS UI | 自动语音发送、快捷语音发送、取消识别、长 Markdown 回底、阅读位置保持、键盘发送共 6 条路径通过；点击入口修正后重跑两条受影响路径通过 |
| 真机 | Release 构建、签名校验、安装、成功启动和设备版本回读通过；手持体验待用户验证 |
| Hermes 实际调用 | 问候实际 prompt 5508 tokens，首字 3.01 秒；按需 memory 模块首请求 5548 tokens，完成 5.81 秒；未达到所有轮次首字 2 秒的目标 |
| 实际 L0 查询 | 最近账单 64.71ms、提醒列表 2.29ms、今日日程 59.06ms；只读业务，未向真实聊天写测试消息，也未写账本 |

本次优先落地 Context Builder、Router 与现有 Domain Services 的共用边界。HTTP/SSE Gateway、完整跨运行时适配及两端自动生成网络模型没有在本次重写；这避免把性能修复扩成无必要的整体迁移。现有 SQLite 和手机导航结构保持。原始证据在 `verification/iteration-20261007/`，包括 native 请求实测、业务只读实测、XCTest 结果、安装及版本回读。

## 现场原因与实测

此前对当轮任务和记忆做过裁剪，但 Hermes 的原生会话仍保留旧的大型上下文包装及工具回执。这些历史内容会继续进入模型请求；每轮还会先等待自动语义召回。当天部署前主聊天的 193 次模型调用，输入 token 中位数为 110,577，单次模型调用耗时中位数为 7.2 秒。一次用户交办通常包含多次模型调用，因此 7.2 秒不是用户整轮等待时间。

新版本的只读验收使用相同模型，独立会话，不向真实聊天发送测试消息，不写永久记忆：

| 场景 | 首次请求实际 prompt tokens | 首段文字 | 整轮完成 | 行为 |
| --- | ---: | ---: | ---: | --- |
| 简单回复 | 5,479 | 2.60 秒 | 2.67 秒 | 无工具、无记忆请求 |
| 带真实近期聊天的简单回复 | 6,519 | 2.38 秒 | 2.42 秒 | 近期工作集 4,051 UTF-8 字节；无工具 |
| 按需读取 memory 模块 | 5,500 | 5.40 秒 | 6.38 秒 | describe 后加载模块，返回版本与权威规则 |
| 检索原始历史 | 6,535 | 6.82 秒 | 7.94 秒 | describe 后调用 context_read，返回带消息 ID 的片段 |

新请求首次携带 8 个工具。其余工具仍可发现和调用，不一次注入全部参数说明。上述新旧样本任务不同，并非严格配对实验，不能据此声称所有任务提速固定倍数。真实 prompt token 含缓存读取部分；字符、UTF-8 字节、估算 token 和提供商实际 token 分开记录。

语义检索服务健康端点正常，但实际召回超过了 4 秒响应预算。已增加当前 Markdown 的直接片段检索作为回退；现场查询在 4.01 秒返回 5 条带当前文件哈希的结果，共 4,939 字节。返回值明确区分语义预算超时与记忆不存在。语义服务本身的延迟仍存在，普通聊天已不等待它。

## 后端实现

- `hermes_prompt.py`：主契约缩为 1,193 字符，保留身份、必要授权边界、真实来源、业务回读和持久任务规则。
- `context_working_set.py`：从 Com 原始聊天组装最近最多 8 条、合计最多 14,000 UTF-8 字节的历史；旧包装和工具轨迹不自动重放。`context_read` 可检索历史，再按消息 ID 与字符游标继续读取长原文；搜索结果以 has_more 和 next_before 指明是否仍有更早匹配，避免把一页误当成全部。
- `context_modules/`：memory、business、tasks、personal 四个短 Markdown 流程。模型需要对应流程时才读取正文。
- `hermes_runtime.py`：使用 Hermes 原生 `conversation_history` 参数提供非空工作集；同一请求的工作集冻结，重试不因后续消息改变幂等指纹。工作执行器仍保留各自任务上下文。
- `memory.py`：取消主聊天自动召回；显式召回时结合当前版本的个人事实、经过来源校验的语义结果和当前 Markdown 片段。事实更正优先读取现行版本，索引落后或超时不回退到已被替代的版本。
- `background_events.py`、`conversation.py`：Hermes 后台事件使用独立会话及消费循环，不再占用前台对话的运行对象和串行消费等待。
- `optimize_hermes_profile.py`：按原生配置启用工具延迟加载，目录预算 800 token；仅保留 5 个常用原生工具和 3 个发现桥接工具。精简重复 SOUL，关闭冗余原生 background review；Com 自有后台业务保持运行。
- `hermes_metrics/`：通过 Hermes 原生请求钩子记录尺寸、工具数量、时间及提供商 usage，不保存正文、工具参数或凭据。钩子提供的 payload 可能经过裁剪，尺寸统计标明这一限制。

## iOS 修复

“回到最新”确实存在点击未进入按钮事件的情况。按钮现在作为滚动内容之外的独立控件，使用至少 44 点的点击区域，避开文本选择和滚动内容的命中干扰。跳转直接跟随内容底部，取消跨大量可变高度消息的长距离弹簧动画。

拖动与惯性减速期间暂停自动跟随；在底部时才跟随新回复。读取更早历史保留可见消息锚点。消息排序仅在消息或待发队列变化时重算；普通气泡不再每帧回传几何位置，只有发送飞行动画需要时测量。批量缓存序列化、加密、写盘迁到独立 actor，待发队列仍保留发送前落盘保证。

附带修复了发送异步等待期间队列变化引起的索引错位，按请求 ID 更新正确消息；失败消息回到草稿时恢复引用和附件 ID。缓存密钥首次创建加锁，避免新增后台缓存写入与主线程首次创建竞争。

图标复用现有白蓝双脸高分辨率母版，采用已确认的 Android 自适应图标中心视野，让脸占据更多画布。浅色、深色、tinted 三个资源同步更新。

## 验证与边界

后端完整回归 511 项通过；独立 ComCore 恢复与传输检查 96 项通过；最终模拟器 XCTest 3 项、UI XCTest 13 项通过。UI 覆盖五板块、详情、语音入口、键盘和发送、失败草稿恢复、历史阅读，以及 301 条混合长 Markdown 消息的滚动和两次回到最新。

真机签名构建与安装成功。702 解锁后启动成功；用户进一步明确问题是滑动位置乱跳，手机并不掉帧。703 取消内容高度变化触发的自动回底，但用户仍复现，清除后台重开也未改善。704 使用 Release 构建，将 LazyVStack 改成每段 60 条的普通 VStack，避免滑动时长 Markdown 的布局高度被重新估算；较早记录按需展开，搜索定位同步扩展显示范围。704 四项针对性模拟器 UI 测试通过，安装及启动成功；用户实际来回滑动后确认“滑动位置已稳定”。真机 UI 测试运行器缺少签名 profile，未把模拟器通过视为实际问题解决。AppIntents 的既有 SSU archive 诊断未导致构建失败。

证据位于本机忽略目录 `verification/context-ios-20261007/`：`baseline-metrics.json`、`model-metrics.jsonl`、`live-probe.log`、`real-history-probe.log`、`memory-live-final.log`、`backend-final.log`、`core-final.log`、`final-ui.xcresult`、`device-install.log`、`device-launch.log`。原有未提交修改另存为 `preexisting.patch`，未混入回滚覆盖。

## 参考与采用范围

[Hermes 原生工具搜索](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/tool-search.md)已经提供延迟 schema 加载，因此本次复用现成运行时能力；没有另造路由模型。[Pi skills](https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/docs/skills.md)采用简短能力描述加按需读取正文，本次 Markdown 流程沿用这一原则。[Anthropic 工具搜索说明](https://www.anthropic.com/engineering/advanced-tool-use)也说明工具发现可减小请求，但发现本身会增加调用往返；本次保留常用工具直达。

[Dot 官方介绍](https://help.openai.com/en/articles/20001530-getting-started-with-your-dot)和 [Muse 官方介绍](https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/)可参考长期记忆、目标和后台工作的产品体验，但不足以证明其内部采用何种上下文拼装方案。本次没有将推测当成它们的实现事实。iOS 排查遵循 [Apple SwiftUI 性能说明](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance)，减少滚动期间无关的视图更新及主线程工作。

## 回滚

Mac mini 的原始 profile 配置和 SOUL 备份在 `~/.session-workbench/backups/context-v2-20261007-222216/`。需要回滚时，先确认无前台请求或活动运行，再恢复该目录的 config 与 SOUL，恢复本次修改的源文件并重启 `ai.hermes.com-personal` 与 `work.eddie.sessions`。不要使用仓库全量 reset，以免覆盖任务开始前的修改。新增工作集与指标表可保留，原始聊天、任务和 Markdown 未迁移或清空。

重新部署本次优化使用 `backend/optimize_hermes_profile.py`；旧 `deploy_hermes.py prepare` 是历史迁移脚本，会改写模型配置，不用于本次更新。
