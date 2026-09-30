# 灵动伙伴预览组件

此目录复制自本工作区 `work/内容生产/动画复刻/Grok灵动助手/web/`，接入的是该工程 v2 的 Lottie 造型与 JavaScript 行为控制器。原工程及独立旧 SVG 均保留。

原始设计参考：AB Works / Novra 的 [Grok Bot 案例](https://www.novra.design/case-studies/grokbot)。该参考是独立概念设计，本资源不是 xAI 官方产品组件，也不包含原作者 Rive 文件或参考视频。

Lottie Web 来自 Airbnb，MIT 许可证随 `vendor/LICENSE-lottie-web.md` 保存。其余组件与矢量动作来自上述本地项目，来源和完整说明请查阅原工程 README。

## 状态映射

- 工作中 → `setState('thinking')`
- 等待回应 → `setState('curious')`
- 已完成 → `setState('happy')`，2.2 秒后自动回 `idle`
- 点击由组件自身处理，3 秒内连续点击为好奇 → 小别扭 → 转晕，结束后恢复业务态。
- 角色的临时表情不修改页面任务状态。任务、连接和进度文案均是预览模拟数据。

本地脚本按 Lottie Web → bot-data → bot-controller → grok-bot 的顺序加载，不使用 CDN 或外部字体。移动端与减少动态效果行为沿用原组件。
