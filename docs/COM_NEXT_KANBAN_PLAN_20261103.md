# Com「下一步」四列拖拽看板 · 落地方案（2026-11-03）

> 来源：Eddie 11-03 需求「待办卡片做成可直接拖拽的 todo 卡片：建议 / 需要做 / 正在做 / 已完成，丝滑、适合 Duo」。
> 三个 agent 分头只读调研（数据流 / 拖拽交互 / Duo 布局），本文是主会话合成后的定稿草案；标「待定」的等 Eddie 拍板。

## 1. 数据：看板只是视图，不新建真源

| 列 | 真源 | 说明 |
|---|---|---|
| 建议 | `next-steps.sqlite` items `state=open` | 和行动台撞上的不显示；最多 5 张 + 2 张「已备好」（现上限 10，收紧） |
| 需要做 | 行动台 md `flow: 任务` + `状态: 待处理` | 按 `计划结束` 排，过期标红；>8 张折叠 |
| 正在做 | md `状态: 进行中` | 有进行中航程（cases ACTIVE）就挂「Com 在办 · 第 x/y 步」徽标；软上限 3 |
| 已完成 | md `状态: 已完成` 且近 2 天 + next `done` | 最多 10 张，更早的看 Dataview 任务索引 |

不进看板：dismissed / stale / resolved；snoozed 只在建议列头显示「明天回来 N 条」。

**必须先修的两个现状问题（11-03 实测）**
- `任务/待处理/` 83 个 md 里 72 个已是 `状态: 已完成` 却没挪走：auto-move 插件实际不生效，**目录≠状态，一律按 `状态` 字段读**。
- 后端只扫 `待处理/`（`today.py` todo_index/todo_create、`next_steps.py` board 采集）；`reminders_sync.py` 按「在不在 `已完成/` 目录」勾提醒 → 改按 `状态`，`进行中` 也同步为未完成提醒。

## 2. 接口

- `GET /personal/board` → `{version, columns:{suggest,todo,doing,done}}`，每卡带 `rev`（md 用 mtime_ns，next 用 updated_at）。
- `POST /personal/board/move` `{op_id, card:"next:<id>|todo:<com_id>", to:"todo|doing|done|out", rev, reason?}`
  - 语义是「设成目标状态」，不是切换；`op_id` 进 `board_ops` 表，重放返回上次结果（幂等）。
  - rev 对不上 → 409，客户端重拉；写 iCloud 加 8s 超时 → 503 回滚（mini 读 iCloud 会卡，见 ref_mini_icloud_wedge）。
  - Com 只改 `状态`/`完成时间` 两行，不挪文件；md 按新增 frontmatter `com_id` 在 `任务/`、`待处理/`、`已完成/` 三处找。

| 拖拽 | 写入 |
|---|---|
| 建议 → 需要做 | 复用 `next_to_todo` |
| 建议 → 正在做 | 同上，`todo_create` 加 `state='进行中'` |
| 需要做 ↔ 正在做、已完成 → 往回 | 新增 `todo_set_state`（由 todo_done / todo_undo 泛化） |
| → 已完成 | md：`todo_done`；建议卡：`act('done')` |
| 拖出（划掉） | 建议卡：`act('dismiss', reason)` 弹四个理由；md：写 `状态: 已取消`（待定），不删文件 |
| 需要做 → 建议 | 不允许 |

**「正在做」= 只改状态，不自动交办**（三方一致）。详情页里明确点「让 Com 先备料 / 交给我办」才建航程；航程跑完不自动 todo_done，停在「正在做」标「Com 办完 · 待你确认」，由 Eddie 自己拖进已完成（守「最终点击由他」）。

**去重**：一件事一张卡，有 md 以 md 为准。`todo_match` 的索引扩到 `进行中` + 近 7 天 `已完成`；看板模式下 `in_todo` 命中直接不显示；撞进行中航程的建议也不显示；建议之间继续用 11-03 的 `_dup`。

## 3. 布局：按看板容器宽度 W 决定，不看屏幕/sizeClass

| 形态（实测/估算内容宽） | W 档 | 布局 |
|---|---|---|
| A Duo 外屏竖拿 ~356pt · E iPhone 17 竖 ~362 · D Duo 内屏横拿双栏右栏 345–442 | < 560 | 单列 + 顶部四段胶囊（建议 3 / 需要 5 / 正在 1 / 完成） |
| C Duo 内屏竖拿 ~629 · B 外屏横拿 ~638（高仅 ~300，未验收过） | 560–819 | 一次两列横滑、按列吸附、露出下一列一截；右侧常驻 56pt「已完成」投放栏 |
| 看板专注模式（隐藏聊天栏） | ≥ 820 | 四列并排，卡片紧凑版（待定是否做） |

- 尺寸：页边 `Layout.margin` 20，列距 `Space.md` 12，卡距 `Space.sm` 8，卡内边距 `Space.md`、圆角 `Radius.md`、最小高 64；列宽 min 260 / 理想 300；列头高 44（列名 + CountBadge + 「+」44×44，已完成列无「+」）；列底 `DockSpacer`。
- 折叠/展开会重建视图：`boardFocus`（当前列）和 `boardAnchor[列]`（`scrollPosition(id:)`）放进 AppModel；切布局那一帧 `transaction.animation=nil` 再 `ComMotion.crossfade`；进行中的拖拽直接取消、无动画复原。
- 原下一步页其他内容：等你拍板 / 结果待核对 / 信源断了 → 看板上方一条可折叠提醒条（拍板仍排第一）；外屏速览卡保留，取「正在做」第一张，无则「需要做」第一张；账本、固定任务、定过的事、周统计 → 页眉「⋯」更多面板。

## 4. 拖拽交互

**选型：自研**。UIKit `UILongPressGestureRecognizer`（经 `UIGestureRecognizerRepresentable`，0.30s、allowableMovement 8pt，移动先于长按就让给滚动）+ 挂在 ScrollView 外的浮层跟手 + 自算插入位。不用 `.draggable`（预览/起拖时长不可控、拿不到插入位置、不自动滚），不用 UICollectionView 拖放（交互式移动限单 collection，十几张卡用不上）。

| 时刻 | 视觉 | 触感 |
|---|---|---|
| 按下 120ms | 缩 0.985（ComMotion.press）预告 | 预热 |
| 300ms 起拖 | 浮层 1.04、上移 4pt，阴影 r12→28 / y3→16 / α.05→.18；原位虚线占位 | impact medium 0.8 |
| 移动 | 倾角 = 横速/1200×4°，夹 ±4°，spring(0.3,0.8) | — |
| 进新列 | 列底 accent 8%、列头 accentText，smooth 0.18 | impact light 0.6 |
| 插入位变 | 其他卡让位，新 token `reflow = spring(0.28, 0.86)`，8pt 滞回防抖 | selection |
| 贴边 | 左右 48pt 停 350ms 翻一列（之后每 600ms），上下 64pt 连续滚 ≤900pt/s 二次加速，底部让开 Dock 72pt | 翻列 selection |
| 放下 | 飞向占位框 ComMotion.flight，复原缩放倾角 | Haptics.sent |
| 取消 | 回原位 spring(0.42,0.82) | — |
| 进已完成 | 圆环描边 0.22s → 勾 bounce → 删除线 0.2s → 停 350ms → settle 收成 44pt 紧凑行 | success |

- 单列模式：拖起时分段胶囊 34→44pt 变投放目标，停 0.4s 切列（底色左→右填满作倒计时），直接在胶囊上松手放该列顶部。**不做左右滑翻页 / 滑动挪卡**（会和原左滑划掉、横滚抢手势；原左滑划掉也取消，划掉走详情或拖出）。
- 不拖也能完成：长按菜单 / 详情 sheet 里「移到…」四项；VoiceOver `accessibilityActions`「移到 X / 上移 / 下移」并播报。
- 看板卡瘦身：标题 2 行 + 一行元信息（≤3 个依据来源图标 + 等对方/进展中标签）；「现在」用左侧 3pt 强调色条；正在做列多一行最新进展。why / 动作草稿 / 依据袋（弹簧参数不动）/ 主动作 / 菜单都进详情 sheet（`.medium/.large`，用普通 sheet，不用 zoom 转场——黑边和重影坑）。卡上无按钮：点开详情、长按起拖。
- 乐观更新：松手即改本地；>600ms 未回包卡降 0.7 不透明度且不可再拖；失败 settle 回原位 + 摇头（0,-6,6,-3,0 / 0.32s）+ error 触感 +「没挪成，卡还在原处——可以再拖一次」4s；拖拽中冻结后台推来的 nextData，松手后再合并。
- 坑：iOS 18+ ScrollView 里 DragGesture 吃滚动 → 用 UIKit 长按 + 拖拽时 `.scrollDisabled(true)`；命中用的列/卡 frame 和浮层同一坐标系（`.named("board")`）；浮层与胶囊不用 `glassEffect`，阴影画在背景形状上，列内普通卡用细描边不用阴影。

## 5. 分阶段

| 阶段 | 内容 | 验收 |
|---|---|---|
| P0 | 后端按 `状态` 读 + `进行中` 支持 + `com_id`；`GET /board`、`POST /board/move`（含幂等/409/503）；reminders 按状态；iOS 看板（单列胶囊 + 两列横滑 + 已完成投放栏）、自研拖拽、详情 sheet、「移到…」 | pytest 覆盖每种移动、op 重放只写一次、rev 错 409；Duo 模拟器 A/C/D 截图 + 「C 选正在做滚到第 4 张 → 合上 → 展开」位置保持；在 mini 真拖一张，md 和提醒事项都变 |
| P1 | 航程徽标与备料按钮、航程完成停「待你确认」、撤销 toast、iCloud outbox、上限生效、（看板专注四列） | 交办一张，跑完停正在做，自己拖进已完成后提醒勾掉 |
| P2 | 列内手动排序（rank）、拖拽数据进打扰精度 week_report | 周统计能看到拖拽数 |

验收启动：`SIMCTL_CHILD_COM_PREVIEW_TAB=下一步 SIMCTL_CHILD_COM_PREVIEW_BOARD=正在做 xcrun simctl launch <UDID> work.eddie.com --ui-testing -appearance light`（`COM_PREVIEW_BOARD` 为新增 DEBUG 参数，每列塞 ≥5 张样例），等 10s+ 再截；Duo 模拟器 `Duo-Com`，姿态用 cua-driver 点 DeviceHub；标准 iPhone 17 模拟器需在 27.1 运行时重建。

## 已定（Eddie 11-03）
1. **做「看板专注」模式，进 P0**：容器够宽（Duo 内屏横拿/双栏、iPhone 横屏）时，下一步页可把左侧聊天栏收起来，四列并排。默认值和入口见 §6。
2. md 卡划掉写 `状态: 已取消`，不删文件（默认，Eddie 未反对）。
3. `待处理/` 里 72 条已完成积压不动，看板按状态读（默认）。

## 6. P0 接口契约（前后端按此并行开发，改动须两边同步）

所有路径走现有 `/personal/*` 鉴权；iOS 用 `AppModel.load("/personal/board")` 读、`mutate("/personal/board/move", fields:)` 写（mutate 会自动带 `request_id`，后端把它当 op_id 用）。

`GET /personal/board` →
```json
{"version": "<所有卡 rev 拼起来的短 hash>", "updated_at": 1793686314.1, "snoozed": 2,
 "columns": {"suggest": [Card], "todo": [Card], "doing": [Card], "done": [Card]}}
```
Card：
```json
{"id": "next:<next_id>" | "todo:<com_id>", "kind": "next" | "todo", "column": "suggest|todo|doing|done",
 "title": "…", "rev": "<字符串>", "urgency": "now|today|week|",  "phase": "new|progress|waiting|ready|",
 "due": "YYYY-MM-DD" | "", "overdue": false, "sources": ["mail","event"],   // ≤3 个，取 evidence kind 去重
 "progress": "最新一步进展文字或空", "completed_at": 0,
 "case": {"id": "…", "status": "running|waiting|done", "step": 2, "total": 5} | null,
 "next": { 原 /personal/next 里完整的 item（why/evidence/action/prompt/ticket/history…）} | null,
 "todo": {"path": "vault 相对路径", "project": "关联项目", "next_step": "下一步", "url": "obsidian://…"} | null}
```
排序：suggest 按 urgency→score；todo 按 overdue→due；doing 按更新时间倒序；done 按 completed_at 倒序。上限见 §1。

`POST /personal/board/move` body：`{"request_id": "<op_id>", "card": "<Card.id>", "to": "todo|doing|done|out", "rev": "<Card.rev>", "reason": "elsewhere|others|unimportant|not_mine"(仅 next 卡 out)}`
- 200 → `{"ok": true, "card": Card | null(out 时), "version": "…"}`；同一 request_id 重放返回首次结果。
- 409 `{"detail": "这张卡刚被改过，已重新拉取"}`（rev 不符）；503 `{"detail": "行动台读写超时，卡还在原处"}`（iCloud 超时）；400 非法移动（如 → suggest、未知 card）。
- next 卡移到 todo/doing 后返回的 Card 是新建的 `todo:<com_id>` 卡（id 变了，iOS 用返回值替换本地那张）。

看板专注（iOS 侧，后端无关）：`AppModel.boardFocus: Bool`（持久化到 UserDefaults），只在 `splitView == true` 且 tab == .next 时生效：隐藏左栏，下一步页拿满宽 → W≥820 四列并排。下一步页眉放一个切换按钮（SF Symbol `rectangle.split.3x1` / `sidebar.left`），离开下一步 tab 时左栏照常显示。
