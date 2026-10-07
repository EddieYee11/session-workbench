# Com! iOS 设计与参考记录

更新：2026-10-07。方向 D「层级」：保留青柠 + 珊瑚品牌，以统一令牌与组件重排全部页面。

### 跨端图标与伙伴形象

- 桌面图标复用 Android 的双伙伴原始素材 `docs/assets/com-companions-master.png`，导出为 1024px 无透明通道图标；普通、深色与系统着色版本共享相同构图。生成入口：`swift ios/scripts/RenderIcon.swift ios/Com/Assets.xcassets/AppIcon.appiconset docs/assets/com-companions-master.png`。
- Hermes 主聊天、工具栏、配对与空状态使用 Android `CrabAvatar.kt` 的珊瑚橙像素螃蟹。SwiftUI Canvas 复用其像素网格、白边、三组脚、颜色、表情及状态装饰；不再使用此前圆润的螃蟹头像。
- 状态由实际录音、发送、执行和连接状态驱动；只有明确成功状态才显示成功表情。后台和减少动态效果时停止循环，保留手动拖动反馈。工具栏头像仅绘制紧凑伙伴，避免与菜单触摸冲突。

## 设计系统 · 方向 D「层级」（2026-10-07）

在方向 C 的品牌基础上（奶油画布、白色内容、青柠主操作、珊瑚螃蟹伙伴）做整体重排：一套令牌、一套组件、每屏一个焦点。`Views/DesignSystem.swift` 是唯一来源，页面不得自行写字号、颜色、圆角或卡片样式。

### 令牌

| 类别 | 令牌 | 说明 |
|---|---|---|
| 层级 | `background` → `surface` → `elevated`，`fill`（卡内嵌入：输入框、代码、引用、指标）、`separator` | 浅色：#F4F3EF / 白 / 白；深色：纯黑 / #1C1C1E / #2C2C2E |
| 文字 | `textPrimary` / `textSecondary` / `textTertiary` | 系统 label 色阶，自动适配深色 |
| 品牌 | `accent`（青柠，只做填充）、`onAccent`、`accentText`（可读的青柠，用于文字与图标）、`coral`（伙伴） | 青柠永远不直接做浅底上的文字 |
| 状态 | `success` / `warning` / `danger` / `info`，统一经 `Tone` 输出 `color` 与 `soft` 背景 | `statusTone(_:)` 把后端状态一次性映射到色调 |
| 焦点 | `ink` / `onInk` / `onInkSecondary` | 今日焦点卡与用户自己的消息气泡 |
| 字体 | `largeTitle 34` · `title 22` · `section 20` · `headline 17` · `body 17` · `callout 16` · `rowTitle 16 semibold` · `subheadline 15` · `footnote 13` · `caption 12` · `metric` · `code` | 全部为语义字体，支持动态字号 |
| 间距 | `xxs 2 · xs 4 · sm 8 · md 12 · lg 16 · xl 20 · xxl 28 · xxxl 40`；`Layout.margin 20`、`sectionSpacing 28`、`rowInset 64` | |
| 圆角 | `xs 8 · sm 12 · md 18 · lg 22 · xl 28`，全部 continuous | 卡片 22、焦点卡与输入区 28 |
| 层高 | `elevation(.flat / .raised / .floating)` | 深色模式下 raised 不投影，靠表面色区分 |

### 组件

- 骨架：`ScreenScaffold`（原生大标题，滚动收起；副标题 + 数据新鲜度 + 右侧主操作一行），`ScrollPage`（弹层/推入页），`DetailPage` + `DetailHeader`（详情三段：头部 → 决定 → 展开）。
- 分组：`GroupSection`（20pt 节标题 + 尾部操作 + 脚注），`Card`（standard / inset / highlighted(Tone) / ink），`GroupedCard`（一张表面内的分组列表，自动发丝分隔线）。
- 行：`ListRow`（图标徽章 · 标题 · 状态 · 副标题 · 元信息 · 尾部），`KeyValueRow`，`NavigationRowLabel`，`RowButtonStyle`（按压高亮）。
- 标识：`IconBadge`（36pt 圆角方块）、`StatusPill`、`StatusDot`、`Eyebrow`（仅英文）。
- 操作：`.primaryAction / .primaryFull / .primaryCompact`（青柠胶囊）、`.secondaryAction`（中性填充胶囊）、`.quiet`（文字操作，destructive 自动变红）、`CircleActionButton`。
- 控件与状态：`FilterChips`、`SearchField`、`MetricTile`、`CodeBlock`、`EmptyState`、`LoadingState`、`InlineNotice`、`Freshness`。
- 外壳：每个标签页使用原生 `NavigationStack` 工具栏——左侧伙伴头像菜单，右侧搜索与设置（iOS 26 自动 Liquid Glass）；聊天页把「Com + 在线状态」放在标题位置。底部为悬浮 Liquid Glass 胶囊 Dock，选中项展开为青柠胶囊并显示名称。

### 原则

1. 每屏一个焦点：今天 = 今日焦点卡；任务 = 待批准提案置顶；工作台 = 「新建工作」主按钮；聊天 = 输入区。
2. 列表统一为分组卡片（GroupedCard + ListRow），不再一行一张浮卡。
3. Liquid Glass 只用于悬浮控件：工具栏、Dock、回到最新消息胶囊。内容保持不透明。
4. 文字层级最多四级：节标题 20 → 行标题 16 → 副文 15 → 元信息 13。
5. 错误与提示统一 `InlineNotice`，后端返回的文字原样显示。
6. 深浅色都由令牌决定；默认浅色，设置可切换深色或跟随系统。

### 各页布局

- 聊天：原生导航栏（头像菜单 / Com 状态 / 搜索与设置）；空状态为伙伴动画 + 问候；助手消息去气泡，用户消息为深色 ink 气泡（发送飞行层同款）；引用带青柠竖条；附件为胶囊；工作过程收进 inset 块；输入区为 28pt 圆角悬浮表面。
- 今天：大标题 + 日期 + 新鲜度 → 今日焦点 ink 卡 → 值得留意（分组列表）→ 日程（色条行 + 来源脚注）→ 账务大数字卡 → 身体与状态（指标网格）→ 数据连接（分组 + 「管理连接」）。
- 任务：分段切换任务/定时；待批准提案（warning 描边卡）置顶；筛选胶囊 + 分组任务列表；详情页为状态胶囊头部、验收卡（accent 描边）、控制卡、步骤时间线、成果与展开区。
- 记忆：搜索 + 分类胶囊 + 统计 → 分组列表；共享知识用 info 色调；详情正文放在白卡内，原始来源与历史版本收进分组展开区。
- 工作台：大标题右侧「新建工作」主按钮；执行器分段 + 搜索；按项目分节的分组会话列表（执行器图标、状态色）；新建工作为分节表单 + 底部固定主按钮；会话详情使用与聊天相同的输入表面；审批卡为 warning 描边并以选项卡片作答。
- 设置：iOS 分组设置样式，说明文字移至节脚注；分享收件箱、设备回执、搜索、语音小窗与配对页统一换用同一套组件。

此前「方向 C」与 Muse 的视觉记录见 git 历史；本节替代其中的版式描述。

## 信息架构

- 聊天：Hermes 持续主线、附件、任务卡、成果和语音输入；录音结束后自动转写，确认或编辑后发送。
- 今天：焦点简报、后续事项、日程、账务、健康与来源连接。
- 任务：状态筛选、步骤、补充、取消与恢复、有证据的验收。
- 记忆：分类、搜索、全文、原始来源；共享知识只读，个人记忆保留纠正入口。
- 工作：执行器筛选、项目会话、新建与恢复、模型、审批与终端。

五个功能入口仍在底部。VoiceOver 保留名称、选中状态，正文采用动态字号。测试截图使用隔离的 Debug 数据，不读取凭据、不调用服务、不写真实缓存。

## 语音与动态效果

两个录音入口复用相同的 `VoiceSessionPanel`：聊天输入区，以及 `Com 语音` App Shortcut / `com-eddie://voice` 打开的原生底部小窗。快捷指令打开前台 Com 后展示小窗；它不是覆盖其他 App 的系统悬浮窗。操作按钮需由用户在 iPhone 设置中绑定快捷指令。

集成 [Libraries.dev voice-glow](https://libraries.dev/voice) 的公开 MIT 组件 `voice-glow 0.3.0`。React 18.3.1 / ReactDOM 18.3.1 打包进离线 HTML，两端复用原组件。iOS WKWebView、Android WebView 不联网；仅接收本机原生音量包络与状态，不接收音频、转写或凭据。录音音量驱动攻击/释放、光束宽度与起伏；转写使用公开 motion 接口形成聚合与扫光。源码与许可证随资源保存，构建入口为 `ios/VoiceEffects/build.mjs`。

文字使用 iOS 原生 TextRenderer，在保留中文排版与换行的同时，按字形错峰出现，以阻尼弹簧位移、三次透明度曲线和模糊收敛形成节奏。减少动态效果时文字直接显示，光效暂停；切入后台暂停光效。录音有 60 秒上限，异常保留文件，发送由用户确认。

## 依赖与验收记录

固定依赖：Textual 0.5.0、SwiftTerm 1.20.0、voice-glow 0.3.0、React / ReactDOM 18.3.1；各自许可证保留。记忆 API 的同步验证位于 `verification/com-shared-memory/`。本轮界面、录音小窗、转写编辑、收起与取消的模拟器检查及构建记录位于 `verification/com-lime-ui/`。

模拟器的音量与转写为明确隔离的测试输入；真实说话音量、硬件操作按钮以及目标手机性能仍须真机操作检查，不能用模拟器截图替代。

## 2026-10-07 · 聊天连续性交互升级

聊天的阅读路径改为：底部锚定的消息流 → 紧邻键盘的输入区 → 从输入文本起飞的短弹簧气泡 → 保持同一请求身份的本地/服务端交接 → 明确送达与执行状态。键盘通过原生安全区调整列表与输入区，底部导航在编辑时收起；正在翻阅历史时保留当前位置，新回复由浮动提示引导主动返回。

本轮产品优先级是改善高频主聊天：减少布局跳跃、解决“已受理但列表尚未刷新”导致的消息消失、保持失败草稿，以及区分送达和执行结果。没有增加缺少真实数据支持的新业务板块，也没有改动服务端执行权限。网络不确定时仍查原请求回执，禁止自动复制提交。

发送动效以请求为单位，380ms 阻尼弹簧，18pt 弧线抬升、轻微旋转与缩放，440ms 落地；起点来自实际输入框，终点在列表滚动与布局完成后从实际气泡获取（50ms布局交接），飞行仅使用变换而不逐帧排版正文。后台、旋转或布局变化导致目标不可见时，850ms 内释放隐藏状态，真实消息始终保留。减少动态效果时直接显示真实气泡，装饰飞行层不接收触摸、不重复 VoiceOver 内容。
