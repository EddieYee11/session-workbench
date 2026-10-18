# Com! 网页版 · 开发规格（交给 Pi 执行）

目标：在 `web/` 下完成纯静态网页（原生 HTML/CSS/JS，无构建、无外部依赖），给 MBP 用，复用手机端 Com! 的视觉与动效。**`index.html` 已写好，不要改结构（可小修）；你要写 `app.css` 与 `app.js`。** 不要改 `backend/`、`android/`。

## 部署与访问
- 页面将挂在 `https://pi.eddiegao.work:8443/sessions/web/`，API 同源在 `/sessions/…`（反代到 mini 的 FastAPI 8650，会去掉 `/sessions` 前缀）。
- `const BASE = location.pathname.replace(/\/web\/.*$/, '')`；本地直开 `/web/` 时 BASE 为空串。所有 API 用 `fetch(BASE+path, {headers:{Authorization:'Bearer '+token}})`。
- 401 → 清 token，回配对页。token 存 `localStorage['com.token']`（try/catch 包裹）。
- 配对：`POST /pair {code}` → `{token}`；也支持 URL hash `#token=xxx` 一次性写入后用 `history.replaceState` 抹掉。
- 联调用：`ssh mini 'cat ~/.session-workbench/token'` 取 token（**不要把 token 打印到输出或写进任何文件**）。本机可 `curl https://pi.eddiegao.work:8443/sessions/health` 验证连通。

## 视觉与动效（沿用手机端）
- 色板：Ink `#1C1D19`、Paper `#F6F4EE`、Sidebar `#F0EDE5`、Card `#FFF`、Muted `#74756E`、Faint `#93958C`、Line `rgba(28,29,25,.06)`、Accent 青柠 `#D1F263`（Soft `#EAF4CC`）、Pi 绿 `#4A7149`(Soft `#E6EDDF`)、Danger `#BD493E`、Amber 背景 `#F7EEDF`/边 `#E9D8B7`/字 `#85662A`、助手气泡 `#ECE8DF`。全部写成 `:root` CSS 变量；暗色模式用 `prefers-color-scheme: dark` 重定义（背景 `#141512`）。
- 「青柠 + Liquid Glass」：`.glass` = 半透明白底 + `backdrop-filter: blur(24px) saturate(1.4)` + 1px 白色内描边 + 柔和大阴影，大圆角（16–24px）。`.bg` 里三个 `<i>` 做缓慢漂移的青柠/暖粉/蓝灰模糊光斑（`@keyframes drift`，30s+）。
- 动效：全部用 `transition`/`@keyframes`，弹性曲线 `cubic-bezier(.2,.9,.3,1.2)`；尊重 `prefers-reduced-motion`（关闭位移与漂移）。必须有：①标签切换淡入+8px 上移；②新消息气泡 slide-up+fade；③发送时用户气泡从输入框位置弹入；④「思考中」三点跳动；⑤批准卡处理后高度折叠+变灰；⑥侧栏选中项青柠胶囊滑动；⑦连接状态点呼吸；⑧按钮按压 scale(.96)。
- 左侧 `.rail`（glass，宽 ~92px，窄屏<760px 变底部横向导航）：顶部是伙伴 iframe（`#botFrame`，正方形，宽 ~64px）；`#botState` 状态文字；导航四项 今天/对话/任务/更多；底部 `#conn` 连接状态。
- 伙伴控制：`iframe.contentWindow.WorkbenchBot.update({state, running:true, interactive:true, reducedMotion})`，iframe `load` 后再调，且需重试（脚本 defer，可能晚于 load 100ms）。state ∈ idle|listening|thinking|speaking|error|happy|greeting|curious。映射：有 run 在 running/phase 非 completed → `thinking`；存在待批准提案或任务 waiting → `curious`；有失败 → `error` 持续 6 秒后回 idle；run 从 running 变 completed → `happy`（一次性，首次加载不触发）；未连接 → `idle`。`#botState` 文案：空闲/思考中/等你批准/出错了/完成啦/未连接。

## API（均需 Bearer；返回 JSON）
- `GET /personal/conversation` → `{conversation_id, revision, messages:[{id, role:'user'|'assistant', text, status, phase, active_tool, created_at(秒), suggestions:[str], linked_tasks:[...], tasks:[...], work_events:[...], attachments, reference, error}], runs:[{message_id,status,phase,active_tool}], tasks:[...]}`
- `GET /personal/conversation/stream`（SSE，需带 Authorization，所以**用 fetch + ReadableStream 手写解析**，不要用 EventSource）：事件 `snapshot`/`update`（data 同上结构，update 只含变化的消息，按 `id` 合并进本地 Map）、`heartbeat`、`task.progress`（`{kind,tool,source_id}`，kind=idle 以外时可在输入区上方显示「正在用 xxx 工具」）。重连带头 `Last-Event-ID: <最后的 id>`，指数退避 1→2→4→…最多 15s；连接状态点据此变化。keepalive 15s 一次，45s 无任何帧视为断线重连。
- `POST /personal/conversation/messages {request_id:uuid, text}`；乐观渲染本地气泡（`pending`），流里出现同文本用户消息后替换。失败要提示并保留文本可重发。
- `POST /personal/conversation/interrupt`（「■ 中断」按钮，仅在有 run 进行时显示）。
- `GET /personal/today` → `{date, events:[{id,title,start,end,all_day,location,calendar}], reminders:[], todos:[], wechat:{title,subtitle,chats:[{name,is_group,mention,summary,at,messages:[{sender,at,text}]}]}, health:{today:{}}}`
- `GET /personal/overview` → `finance.totals`、`finance.month`（只展示本月收支小卡，字段不确定时容错）。
- `GET /personal/next` → `{headline, items:[{id,title,why,urgency,prompt,evidence:[{label}]}]}`；`POST /personal/next/{id} {action:'discuss'|'dismiss'|'done', request_id}`，discuss 会把内容发进主对话，成功后跳到「对话」页。
- `GET /personal/reminders` → `{items:[{id,text,due,repeat,status}]}`（更多页展示未完成的前 20 条）。
- `GET /personal/tasks` → `{items:[{id,title,agent,status,cwd,created_at,updated_at,result,completion_condition,acceptance_passed}]}`。status 取值：running/waiting/unknown/dispatching/cancel_requested/execution_finished/failed/rejected/cancelled/expired。分组：待你决定（waiting + 待批准提案）/执行中（running,dispatching,unknown,cancel_requested）/待验收（execution_finished 且 !acceptance_passed）/已完成（execution_finished 且 acceptance_passed）/已结束（failed,rejected,cancelled,expired）。顶部筛选胶囊，点击任务卡展开详情（prompt 截断 600 字、result、cwd、时间）。
- `GET /personal/work/proposals` → `{items:[{id,title,agent,cwd,sandbox,prompt,reason,status,created_at}]}`；只有 `status==='proposed'` 的显示批准/拒绝卡。批准：`POST /personal/work/proposals/{id}/approve {request_id:uuid, explicit_authorization:true}`——**必须先弹确认对话框（`#dlg`）完整展示 agent、cwd、sandbox、prompt，用户点「允许」才发**；拒绝：`POST .../reject`（无 body）。成功后卡片折叠动画并刷新列表；失败 toast 展示 `detail`。
- `GET /personal/goal-proposals` → `{items:[…]}` 目标提案，更多页只读展示标题。
- `GET /health`（免鉴权）→ 版本信息，更多页展示 `version`、`build_commit`(前 7 位)、`main_operation_mode`。
- 错误体为 `{detail:"…"}`，toast 显示 detail。

## 页面
1. **今天**：问候+日期；「待处理」（待批准提案数、waiting 任务数，点击跳任务页）；日程时间轴（全天事项置顶，进行中的高亮青柠）；提醒/待办；微信摘要卡（`wechat.title/subtitle`，点开展开每个聊天最近几条，@我的有青柠标）；「下一步」建议卡（headline + 条目，三个按钮 讨论/忽略/完成）；本月收支小卡。每 60s 静默刷新，切回标签页时刷新。
2. **对话**：消息流（用户靠右白气泡，助手靠左 `#ECE8DF` 气泡，最大宽 720px 居中容器）；轻量 Markdown（先转义再渲染：标题、**粗体**、`行内码`、``` 代码块 ```、有序/无序列表、`[文本](http(s)://…)` 链接 `target=_blank rel=noopener`）；助手进行中（status/phase 非 completed）显示三点动画 + `active_tool`；气泡下方 `suggestions` 做成可点芯片（点击即发送）；`linked_tasks`/`tasks` 显示为小任务胶囊（点击跳任务页）；时间戳悬停显示；首次只渲染最近 80 条，滚到顶时用 `GET /personal/conversation/history?before=<首条id>&limit=60` 补历史（若返回结构不明按 `messages` 或 `items` 容错）；用户不在底部时来新消息显示 `#jump`「回到最新」；输入框自适应高度（最多 8 行）、IME 合成中 Enter 不发送（`e.isComposing`）、`Cmd/Ctrl+K` 聚焦输入、草稿存 `sessionStorage`。
3. **任务**：见上，加上批准卡置顶。每 20s 刷新（页面可见时），SSE 的 update 到来时也刷新一次（防抖 800ms）。
4. **更多**：连接信息（后端版本、实时连接状态、SSE 最后 revision）、提醒列表、目标提案、「退出配对」按钮（清 token）。
- 侧栏角标：`#chatDot` 有 run 进行时亮；`#taskDot` 有待批准提案或 waiting 任务时亮。

## 代码要求
- 单文件 `app.js` ≤ ~700 行，`app.css` ≤ ~450 行；风格简洁，无框架，无外部请求，**不写任何 innerHTML 拼接未转义的用户/模型文本**（统一 `esc()`）。
- 离线/出错容错：每个板块独立 try/catch，一个接口失败只让该板块显示「加载失败·重试」，不影响其它。
- 页面标题随未读/进行中变化：进行中时 `Com! · 思考中…`。

## 验收（你自己做，并把结果写在最后回复里）
1. `node --check web/app.js` 通过。
2. 取 token 后用 `curl` 或 node 实测：`/personal/conversation`、`/personal/today`、`/personal/tasks`、`/personal/work/proposals`、`/personal/next` 返回的字段与 app.js 里读取的字段逐一对上（字段名不符就改 app.js，不要猜）。
3. 用 `python3 -m http.server`（在 `web/` 目录，端口 8765）起静态服务，再用 `ego-browser`（skill `~/.claude/skills/ego-browser/SKILL.md`）或 Playwright 打开 `http://127.0.0.1:8765/`，向 localStorage 注入 `com.token` 后无法跨域调 API 是预期的——因此联调请改用：在 `web/` 里临时起一个 `proxy.py`（Python 标准库，转发 `/sessions/*` 到 `https://pi.eddiegao.work:8443`，其余走静态文件），**验收完毕删除 proxy.py**。截图检查四个标签页无报错、无布局溢出、无控制台错误。
4. 不要提交 git，不要动 mini 上任何服务；部署由主 agent 负责。
5. 最终回复 ≤ 15 行：做了什么、验证了什么、已知缺口。
