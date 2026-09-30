# Grok 灵动助手 v2 — Android 本地接入

角色、11 个 Lottie 数据及行为控制器复制自用户指定工程：
`work/内容生产/动画复刻/Grok灵动助手/web/`。

该工程参考 [Novra 原作者 Grokbot 独立概念案例](https://www.novra.design/case-studies/grokbot)
及 [ab_workss 参考视频](https://x.com/ab_workss/status/2100984617180242155/video/1)。
角色 / 原始动效的作者署名以原网页为准；此处不包含原作者 Rive 文件或视频，
也不声称本应用为 xAI 官方产品。

- `bot-data.js`、`bot-controller.js`：原工程文件，未改动。
- `grok-bot.js`：保留原造型、跟随和互动逻辑；只新增 `setReducedMotion(boolean)`
  容器接口，并合并浏览器和 Android 系统的减少动态效果设置。
- `vendor/lottie.min.js`：Lottie Web，Airbnb，MIT；完整许可证见
  `vendor/LICENSE-lottie-web.md`，原包内版权声明保持不变。
- `index.html`、`host.css`、`host.js`：会话工作台本地容器。

Android 使用固定虚拟 HTTPS 来源，由 WebViewClient 从随包 assets 提供全部文件；
拒绝其余请求、页面导航和网络加载。没有 JavaScriptInterface，没有远程脚本。

组件仅接受真实业务态；没有上传数据源时不开放 `upload`，也不显示模拟进度。
`happy` / `greeting` 是原组件的一次性状态，结束后回 idle。业务输入去重，
Compose 重组与前后台切换不会重复播放一次性反馈。

容器必须保持正方形；原角色球体约占画布宽度的一半，其余留白用于动作。
