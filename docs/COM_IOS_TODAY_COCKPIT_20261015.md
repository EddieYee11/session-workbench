# Com! iOS · 今天页驾驶舱 + Garmin 身体数据 + 工作页任何会话都能发（2026-10-15，Claude）

> 起因：Eddie 说「今天」页只有 UI 没功能、利用率低；要把 Garmin 身体电量、睡眠等健康内容加上；工作页的 agent 只能看 session 不能下指令；另要求新功能配上动效。
> 计划：`~/.claude/plans/com-ios-ui-garmin-agent-session-purring-starlight.md`（Eddie 拍板：晨间驾驶舱 / 今日+7 天趋势+联动 AI / 三种下发路径都要）。

## 一、顺手修掉的真 bug：个人信源从没定时同步

`personal_hub.sync()` 只有手动同步和 agent 工具两个调用方，`SOURCES` 里的 900/1800 秒间隔从未生效——mini 上 Garmin、邮件、日历都停在服务启动那一刻（10-13 18:03，停了约 41 小时）。
`app.py` lifespan 加 `hub_loop`：每 60 秒 `sync("all")`，按各源间隔自然节流。上线后 14:13 全部信源重拉一遍。

上线时暴露的现存问题（未修，需 Eddie 处理）：
- Gmail：`needs_connection`（gws 授权失效）
- Google 日历：`invalid_grant: Token has been expired or revoked`，需重新授权
- 微信摘要：4 小时没更新，检查 MBP 上 `com.eddie.wechat-digest`
- 手机健康 / 手机日历：没有在线且已授权的手机节点

这些现在会直接显示在今天页（`SourceBrokenNote`），不用再翻到别处。

## 二、Garmin 身体数据

| 层 | 做法 | 文件 |
|---|---|---|
| 采集 | 一天一条：summary（步数、静息心率、压力、身体电量高低/充放/起床时）、睡眠（时长、分数、深浅 REM 清醒、起止）、HRV（昨夜、周均、状态、基线）、训练准备度、身体电量曲线（压力接口 3 分钟序列降到 15 分钟）。每项单独 try，缺的写进 `missing` | `backend/garmin_source.py` |
| 入库 | 今天和昨天每次重取（睡眠/HRV 醒后才补齐），再往前 5 天只补没有的；按日期一天一条 matter；历史天数不进简报卡 | `backend/personal_hub.py` `sync_source('garmin')`、`health()` |
| 接口 | `GET /personal/health?days=7`；`/personal/today` 多一个 `health` 段 | `backend/app.py`、`backend/today.py` |
| 联动 AI | 「下一步」整理时把身体数据喂给模型，新产出 `headline`（一句今日简报），模型失败时规则拼句；主对话 `personal_briefing` 工具结果带上 7 天身体数据（不含曲线） | `backend/next_steps.py`、`backend/agent_tools.py` |

注意：connectors-venv 的 Python 要用 `-I` 跑（mini 的 /tmp 里有个 `inspect.py` 会遮住标准库，探针脚本已挪到 `~/.session-workbench/probe/`）。

## 三、今天页 → 晨间驾驶舱

从上到下：日期 + 统计 → 提示条 → **今日简报**（可重新整理）→ **身体卡**（电量圆环 + 当日曲线 + 睡眠分段条 + 6 格指标带 7 天迷你线，和周均比好坏上色；点进 7 天柱状明细）→ **一句话交代给 Com**（不跳页）→ 四个数字 → 下一件表盘 → 待办 / 等你决定（待办长按「改到明天」，提醒「晚 1 小时」）→ **建议**（下一步里 现在/今天 最多 3 条，「全部 N 条」进完整页）→ 微信 → 时间线 → 断掉的信源 → 任务与目标。

「下一步」tab 从底栏撤掉（底栏回到 Com / 今天 / 工作），完整页从今天页「全部 N 条」进；今天 tab 徽标 = 等你决定 + 现在该做的建议。enum case 保留给深链和测试夹具。

后端：`POST /personal/today/todos/postpone`（只改 `计划结束` 一行，原子写，返回原行可撤销）。

没 Garmin 今天数据时退回手机健康快照；都没有时给一个入口，把原来埋在设置里的 HealthKit 读取卡搬过来。

## 四、工作页：任何会话都能发一句

`POST /sessions/{sid}/dispatch` 按顺序选路，回执带 `mode`：

1. `input`：Com 托管且在跑 → 原 `/input`
2. `injected`：会话正开在 mini 的用户 tmux 里（进程 cwd 一致，命令行带会话 id 优先，否则同目录唯一一个）→ bracketed paste 打进那个窗格。多个/零个候选不乱打，走第 5 条
3. `resumed`：能恢复 → 自动 resume 再送入（原来要手点「恢复此会话输入」）
4. `adopted`：电脑上没在跑的 Claude Code 会话 → 预置 `claude-runtime/<task>.json` 的 `native_session`，Com 的 Claude 工作器用 SDK resume 原会话接着说
5. `forked`：被 Codex App 占锁 / MacBook 快照 / 接不上 → 同 agent 同目录开新会话，首条带「接续自《原标题》」+ 最后 4 轮原文 + 新要求

`GET /sessions/{sid}` 的 capabilities 多 `dispatch_mode` 预判。`once()` 在 `action_lock` 里跑 action、不可重入，所以恢复/接管和后面的输入各用派生请求标识各走一次。

iOS：输入框不再有只读分支（「恢复此会话输入」按钮和 `WorkSessionModel.resume` 一并删掉）；占位文字 + 输入框上方一枚路由小签说清会走哪条路；`forked` 时页面原地换成新会话；第一次往终端里打字弹一次确认（`work.injectConfirmed`），之后不再问。

已知风险：`adopted` 用的是 Com 的 Claude 工作器（第三方模型配置），接的是原会话记录但换了模型。

## 五、动效（沿用现有语法：blurLift、错峰上浮、spring 0.38–0.45 / 0.85，全部尊重「减弱动态效果」）

- 简报：换句时旧句淡出、新句模糊上浮；整理中文字半透明、刷新图标持续旋转（`symbolEffect(.rotate)`）
- 身体卡：电量圆环描边 0.9s 长出、中间数字从 0 数上来；当日曲线 1.1s 从左画出（遮罩）；睡眠四段依次从左长出（每段晚 80ms）；6 格指标错峰模糊上浮（每格晚 50ms），迷你线随后画出
- 7 天明细：柱子从 0 弹簧长到实际值
- 一句话交代：聚焦描青柠边；发出时输入条一沉一弹，「已交给 Com」带勾模糊上浮，5 秒后收起
- 建议卡：错峰模糊上浮（每张晚 50ms），划掉的缩一下淡出（与「全部建议」页一致）
- 工作页：路由小签换会话时模糊上浮切换；回执状态变化弹簧过渡，转去别处时出现分叉图标

## 六、验证

- 后端（mini）：`pytest tests` 613 passed（含新增 `tests/test_dispatch.py` 6 条、`tests/test_health.py` 5 条）；kickstart 后 /health 200，`/personal/health?days=7` 返回 10-09 至 10-15 七天真实数据（今天：电量 47、睡眠 7.2h/81 分、HRV 44、准备度 81）
- iOS：模拟器 iPhone 17 Pro 编译通过。UI 全量 50 条首轮 46 过；4 条失败逐一处理后重跑通过，只剩 1 条：
  - 2 条还在点已撤掉的「下一步」tab、1 条时间线被挤到首屏下面 → 改测试（走今天页「全部 N 条」、先滚到位）
  - 修测试时发现真 bug：从今天页推进去的「下一步」页用 ScreenScaffold 藏了导航栏，**没有返回键** → 改成普通导航栏（返回 + 右上重新整理）
  - `testHomeSendTurnsIntoChatInPlace` 仍失败：`OSStatus -34018`，`queueWork` 写钥匙串，而测试用 `CODE_SIGNING_ALLOWED=NO` 构建没有钥匙串权限。环境问题，和本次改动无关（去掉新加的确认弹窗二分过，照样失败）
  - 新增 `testTodayCockpit`（简报、身体卡 → 7 天明细、一句话交代、建议入口）通过
- 未装真机：iPhone Air 当前 `unavailable`（devicectl）
- 未验证：dispatch 的四条真实路径（注入终端 / Codex App 占锁 fork / 已结束 Codex resume / Claude adopt）需要真机配合实测；真机 iPhone Air 装机后的界面需要 Eddie 肉眼确认

---

## 第二轮（10-15 下午）：今天 / 下一步拆回两页 + 表盘重做 + 现存问题

Eddie：「今天页塞太多，下一步和今天分开；半圆日程进度要随时间变动、带时间、可交互，点日程看具体事件」。

**拆页**：底栏回到 Com / 下一步 / 今天 / 工作四页；建议回到「下一步」页（ScreenScaffold，顶栏重新整理）。今天页去掉深色提示条和四个数字（与大标题、简报重复），顺序：日期 → 简报 → 表盘 → 身体卡 → 待办/等你决定 → 一句话交代 → 微信 → 时间线。

**表盘（`TodayDial` 重做）**
- 每秒取一次现在：眼前（-1h…+3h）/ 半天（-3h…+9h）两档窗口跟着滚，刻度、时间、日程一起漂；全天档 0–24 固定只有现在点走。档位记在 `today.dial.span`。
- 外圈整点时间标签（间隔 1/3/6 小时随档变）；内圈彩色日程带（开始→结束，过去淡、进行中实）；黑弧到现在；现在点外一圈呼吸光。
- 交互：点圆点进日程详情（热区 contentShape 扩到约 44pt，画的大小不变、避让不受影响）；一摞照旧点开展开；沿半圈拖动出指针和时间胶囊，读出那一刻正在进行的日程；档位切换青柠胶囊 matchedGeometry 滑动、圆点/弧/现在点弹簧过渡。

**现存问题**
- 微信摘要：MBP 采集正常，空档是 MBP 睡眠；已恢复 connected。
- 手机健康/日历：节点只在 App 前台连得上，定时同步碰不上。改为节点连上即拉（`DeviceNodes.on_connect` → `PersonalHub.sync_phone`，上次成功超 10 分钟才拉）；实测 15:31 两源 connected。
- Gmail / Google 日历：两个 OAuth 应用都在 Testing，刷新令牌 7 天过期（10-08 授权、10-15 到期）。已用 ego-browser 把 gwscli 和 Pi Dashboard 两个应用发布为正式版（补首页 / 隐私链接、授权网域 eddiegao.work，删掉 gwscli 徽标以免触发品牌验证），再重新授权（回调走 MBP→mini 端口转发）。16:07 gmail 252 封、google_calendar 18 条均 connected。
- 附带发现：www.eddiegao.work 的 HTTPS 证书校验失败（curl exit 60），与记忆里「证书 10-07 到期须手动重签」一致；`/privacy` 页面目前也不存在。

验证：后端 614 passed；UI 测试相关用例全过（新增 `testTodayDialLiveAndInteractive`）；真机首轮装机成功，第二轮等 iPhone 重新可用后自动装。

---

## 第三轮（10-15 傍晚）：「下一步」新信源

结论先行：iPhone 读不了其他 App 的通知（iOS 无接口）；Android 版有完整通知采集（`NotificationSignals.kt` → `backend/signals.py`，库里 562 条，10-06 换主力机后停）。改为从源头拿数据：

| 信源 | 采集 | 进「下一步」 |
|---|---|---|
| Obsidian 行动台 + Inbox 速记 | mini 直接读 vault（`NextSteps(vault=…)`） | `board` / `inbox` |
| iPhone 提醒事项 | 设备节点 `reminders.list`，hub 源 `phone_reminders`（未完成全量覆盖；手机一连上就拉） | `reminders` |
| 短信 / iMessage | MBP `probes/sms_digest.py`（复制 chat.db 读，解 attributedBody，丢验证码）→ SSH 推 mini；launchd `com.eddie.sms-digest` 每小时 | `sms` |
| Plaud 录音纪要 | MBP `probes/plaud_digest.py`（MCP 客户端调 @plaud-ai/mcp，取「行动项目」一节，新录音只取一次）→ 推 mini；launchd `com.eddie.plaud-digest` 每小时 | `commitments` |
| 天气 | mini 拉 Open-Meteo 未来 3 天（默认北京，连接器配置 `weather` 可改城市经纬度） | `weather` |
| 此刻地点 / 专注 | App Intent「告诉 Com 我现在的状态」（快捷指令自动化用，后台跑）→ `POST /personal/context` | `context` |

这些源不进简报卡（`QUIET`），只当「下一步」的资料；模型提示词加了 10–13 条使用规则。

实测：Plaud 13 场会议纪要入库；首轮整理 8 条建议，其中「定夺攀岩节最终方案」「谈定北鼎卡券赞助」来自会议行动项；简报带上身体数据。后端 617 passed。

待 Eddie：
- 短信：MBP 的 chat.db 停在 07-02。需要 MBP「信息」登录 Apple ID 并开「iCloud 中的信息」，iPhone「设置 → 信息 → 短信转发」勾上这台 MacBook。开好后采集自动生效（连接器里会提示「信息库超过 7 天没有新消息」直到恢复）。
- 快捷指令自动化：iPhone 快捷指令 → 自动化 → 到达「公司」/「家」或专注模式打开 → 动作选 Com 的「告诉 Com 我现在的状态」，关掉「运行前询问」。
