# Com! · Pi 主线产品路线图

> 2026-10-03 用户决策修订。当前目标是 `work.eddie.sessions`；OpenMuse 继续作为桥接界面。实现契约见 [任务层契约](TASK_LAYER_CONTRACT.md)，进度与证据见 [实施记录](COM_PI_MAIN_IMPLEMENTATION.md)。下方 1.5.2 性能记录保留为历史，不代表此次接入已验收。

## 一、已确认方向

- Pi 独占持续主对话，使用现有 `opencode-go/deepseek-v4.1-flash`。用户明确取消 Flash 路由对照实验，直接接入；保留协议、恢复和端到端验收。
- 工作页采用 Claude Code / Codex；旧 Pi 会话在工作历史中只读可达。
- Goal、执行状态、输入队列、结果和事件以 Com 后端 SQLite 为真源；长期知识沿用 AI_Work_System。此决定替代原 OpenMuse Postgres 真源及其反向读写桥方案。
- 明确交办范围内积极执行；情绪、愿望、引用与候选任务不授予权限。严重不可逆删除、破坏性覆盖与无法归类的高风险删除需具体批准。恢复性归档须记录恢复依据。
- 同一事项由主对话持续负责，执行器只是运行上下文。已受理、实际送达、执行结束、验收通过分别呈现；自由文本“完成”不等于通过。

## 二、实施顺序与发布门槛

1. v1.6：传输无关工具与结果契约、真实工具时间线、来源与动作授权兜底。
2. 新增 Com 自有 Pi RPC supervisor，接入 mini 第三方 Claude Agent SDK worker，验证事件映射、会话迁移、去重与中断恢复。Hermes 保留配置回滚入口。
3. 隔离固定场景每项重复两次，协议与恢复测试全部通过；重复副作用和误报成功为零，才开启默认 Pi 主线。
4. 真机验收主页、工作页、语音、内外屏和后台恢复后，启用目标调度。

Pi RPC 是新增适配层。旧 Pi tmux 输入、Escape 和 `.pi.jsonl` 不具备原生 steer 送达语义，不能当作已经接通。参考 pi-gateway 协议处理但不共用微信 lane、账号或会话。

## 三、执行与能力

能力扩展既有 `capabilities.py`，按主机、运行时、项目和配置版本登记。discovered 来自文件扫描，loaded 来自运行时报告，verified 来自安全真实探针或生产成功，默认 24 小时有效。配置、依赖、版本变化与失败使验证失效；测试 fixture 不证明生产能力可用，MBP 的配置不能替 mini 作证。

2026-10-03 用户再次修订：主 Pi 是主要执行者，直接拥有 bash/read/write/edit 与业务工具的工作权限；不为 Shell 或项目工作强制派活。Pi 按耗时、独立并行或专门能力自主决定是否委派，可选独立 Pi、Claude、Codex，不强制执行器。当前已落实 A/B/C 选项续答与真实原交办的关联，用户采纳助手示例及末尾残留代码标记不影响明确交办。普通原生文件修改先保存恢复副本；高风险删除/覆盖保留具体审批。后台最多两个，Claude 最多一个。所有受管写任务在 mini，项目写任务在同步目录外包含未提交修改的独立副本执行；验收后按项目串行合入。检查基线和 Syncthing 状态，冲突保留补丁并暂停合入。

Claude 继承 mini 现有第三方 endpoint 与凭据；用户随后明确批准仅 Com 执行器改用 deepseek-v4.1-flash，原全局 Claude 配置保持不变。不切官方 API，不静默回退。自动调用每天三次任务、每任务十二轮、并发一个，续接计入原任务；金额无法核验就标未知。提供完整用量时追加 Token 阈值，不用官方价格冒充真实费用。

## 四、事件、目标与身份

保留 `personal-main`、原消息 ID、request_id 和旧任务 origin，新增运行时映射与切换边界。中断中的操作为 uncertain，不重放。原生事件先映射为内部 run/tool/assistant，再保持手机/OpenMuse 的 snapshot/update SSE。

沿用 `work.eddie.sessions` LaunchAgent 和执行状态 task_loop。持久事件队列由单一主线消费者处理；用户优先，后台事件携带原授权来源。调度器仅登记事件。目标保存完成条件、授权范围、下一步与关联任务；事件即时推进，09:30 Asia/Shanghai 检查可执行目标，没有可推进事件不调用模型。/asr 只转写，快捷语音与主聊天共用请求登记；旧回执继续可读。

## 五、历史 1.5.2 性能基线

设计理念再对，卡顿也会毁掉体验。本轮做了 8 项低风险改动，覆盖「聊天流式与输入卡顿 / 滚动与列表 / 启动与内存」：

| 编号 | 改动 | 影响面 |
|---|---|---|
| E1 | 缓存解密后的 token（原来每个请求、9 个轮询、多个 composition 都跑一次 KeyStore + AES-GCM） | 每次读 token 从「解密」降到「比较字符串」 |
| E2 | 提升正则常量 + 记忆化搜索与行号查找（原来每次重组对每条消息重编译正则、线性扫全表） | 搜索与列表渲染 |
| E3 | 自动滚动改用稳定 key（原来把整条消息 JSON 字符串化当 key，流式时每 token 一次） | 流式输出 |
| E4 | 搜索词持久化去抖（原来每次击键写一次 SharedPreferences） | 打字 |
| E5 | 滚动位置改为静止时写入（原来每变化一行就写一次） | 滚动 |
| E6 | 草稿持久化合并写（内存态仍同步，只对落盘合并；`onPause`/`onStop` 兜底 flush） | 打字 |
| E7 | 回收安装包体积（未签名 release 13.50 → 3.62 MB，**−9.88 MB / −73%**；可安装的 `benchmark` 15.62 → 3.91 MB，**−11.71 MB / −75%**） | 包体 |
| E8 | 停掉权限面板的 2s 轮询（改为申请返回 + ON_RESUME 刷新） | 「更多」页耗电 |

**E7 要特别说明**：那 13 个 `com_icon_*_v1.png`（磁盘上 10.4 MB）**从不被解码**——`ComIcon` 画的是 Material 矢量，PNG 只是被 `R.drawable` 引用着占地方。所以这是**纯包体收益，对启动和内存是 0 影响**（早前把它当成「启动与内存」收益是错的，已纠正）。做法是删掉 PNG、在原目录放同名 24dp `<shape>` 占位，资源 id 不变、20 处调用点零改动。实测 release 打包后少 9.88 MB（aapt2 会对 PNG 做一次重编码，进包体积略小于磁盘体积）。可安装的 `benchmark`（release 优化 + debug 签名）改前 15,621,266 B → 改后 3,907,387 B，少 11.71 MB / −75.0%；这条 A/B 的两端 APK 都留在磁盘上（`verification/com-1.5.2/Com-1.5.2.apk` 与 `android/app/build/outputs/apk/benchmark/app-benchmark.apk`），可复算。包名、versionCode 13、版本名 1.5.2、应用名 `Com!` 均未变，是原位升级。

## 六、历史 1.5.2 校正

写方案时先按旧文档假设，核实源码后推翻了三处，记在这里避免以后重犯：

1. **P0/P2/P3 其实已经实现**。旧文档把它们列进「待做」，实际 `parent_message_id`、`POST /personal/tasks/{id}/input`（steer）、`finish()` → `task_receipt()` 都在。v1.6 因此只收 P1。
2. **PNG 不是内存/启动问题**。见上。
3. **`ic_launcher_art.png` / `ic_launcher_foreground.xml` 不是「在用」的图标链**。manifest 指向 `@drawable/ic_launcher`，自适应图标用的是 `coms_launcher_foreground`；`ic_launcher_foreground.xml` 零引用，`shrinkResources` 在 release 里本来就把它剥掉了。归档它们只是卫生清理，不减产物。

## 七、历史 1.5.2 验收与边界

- 本轮改动**不改协议、不改权限语义、不动任务层**，是纯性能 + 资源清理。
- 验证（已完成，证据在 `verification/com-1.5.2-perf-batch1/`）：单元测试 **44/44 通过**；模拟器 Compose 测试 **44/44 通过**（窄 411dp 跑 2 次、宽 609dp 跑 1 次）；release 产物体积对照见第五节。E6 手工验证：输入草稿 → 离开（触发 onPause/onStop flush）→ 硬杀进程 → 重开，草稿恢复；唯一取舍是「最后一次击键后 350ms 内被硬 SIGKILL」会丢草稿，已记入验证记录。**产出 APK 但不装到手机**，安装时机由 Eddie 定。
- 1.5.2 本身仍有未完成的**实机**验收项（历史及配对界面、豆包语音面板切换、连续键盘升降、内外屏切换、触觉）。本轮改动不替代它们，也不因此延期。
