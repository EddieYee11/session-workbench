# Agent 真实图标 · 来源与生成（轨道 r2-memory，2026-10-10）

工作页的 Agent 头像用的是各家官方图标，不是自己画的。原件在 `src/`，处理后的单色蒙版在 `Com/Assets.xcassets/Agent*.imageset`（template 渲染，App 里按每个 Agent 的品牌色上色）。

| Agent | 原件 | 来源 URL | 处理 |
|---|---|---|---|
| Hermes（Nous Research Hermes Agent） | `src/hermes-icon-master.svg` | https://raw.githubusercontent.com/NousResearch/hermes-agent/main/assets/icon-master.svg （官网 https://hermes-agent.nousresearch.com 的 favicon 也是同一幅女孩线稿：web-assets.nousresearch.com/…/assets/hermes-agent/icon.png，只有 48px） | `dark`：黑线稿 → alpha |
| Pi（badlogic/pi-mono，pi.dev） | `src/pi.svg` | https://pi.dev/favicon.svg | `ink`：黑色块 → alpha，留 12% 边 |
| Claude Code（Anthropic） | `src/claude.svg` | https://claude.ai/favicon.svg （Claude 陶土色星芒；apple-touch-icon 同形） | `ink`：彩色星芒 → alpha |
| Codex（OpenAI） | `src/codex-blossom.dark.png` | Codex 官方 VS Code 扩展「Codex – OpenAI’s coding agent」（openai.chatgpt）的图标：https://open-vsx.org/api/openai/chatgpt/alpine-arm64/26.5908.31748/file/blossom.dark.png | `light`：黑底白花 → alpha |

openai.com / chatgpt.com 对 curl 返回 Cloudflare 挑战页，没法直接取 favicon，所以 Codex 用扩展商店里的官方图标；GitHub 组织头像 https://github.com/openai.png 是同一个 blossom 标，可作备份。

重新生成（SVG 先用 `qlmanage -t -s 512` 栅格化）：

```sh
swiftc -O scripts/agent-logos/MakeMark.swift -o /tmp/makemark
/tmp/makemark claude.svg.png Com/Assets.xcassets/AgentClaude.imageset/agent-claude.png ink 192 0.04
/tmp/makemark pi.svg.png     Com/Assets.xcassets/AgentPi.imageset/agent-pi.png         ink 192 0.12
/tmp/makemark src/codex-blossom.dark.png Com/Assets.xcassets/AgentCodex.imageset/agent-codex.png light 192 0.06
/tmp/makemark hermes-icon-master.svg.png Com/Assets.xcassets/AgentHermes.imageset/agent-hermes.png dark 192 0
```

配色（`WorkHome.swift` 的 `AgentBrand`）：以品牌色为基准降饱和——Claude 暖陶土 #C96442 浅底、Codex 中性冷灰、Hermes Nous 浅靛、Pi 浅薄荷。图标本身保持品牌形状，只换色。
