# Com! Markdown / Hindsight 记忆

Markdown 是唯一权威档案；Hindsight 0.10.2 是可重建的语义索引。没有安装会自动 retain 聊天的官方 Coding Agent 扩展，不摄入 Git、会话或整个工作区。

## 当前范围

- `personal-main`：`_global/本体画像/` 的现役 Markdown；`_global/记忆库/知识/` 与 `事件/`。
- `project-com`：Com! README 与 `docs/` 的 Markdown。
- 排除归档、同步冲突副本、符号链接、大于 512 KiB 的文件和 `memory-reflections/` 提炼草稿。
- 扩展其他项目时修改 `backend/memory.py` 的显式 ROUTES，不扫描所有隐私资料与配置目录。

## 运行链路

mini 的 `work.eddie.com-memory` launchd 服务在 `127.0.0.1:8888` 运行 Hindsight，原生 Python 独立环境 `~/.com-memory/venv`。数据库为 `~/.pg0/instances/com-memory`，中文向量/排序模型缓存为 `~/.cache/huggingface`，不通过 Syncthing 同步运行数据。

模型提炼复用 mini 上 Pi 的 zenmux 配置与 API key；启动时读取，不复制密钥到仓库或 plist。原文会发送到该已配置模型接口提炼，向量与重排序在 mini 本地计算。没有调用其他供应商回退。导入前过滤凭据字段及包含凭据的代码块，召回再次过滤敏感字段；这些规则是保守过滤，原始档案不改写。

`work.eddie.com-memory-sync` 每轮完成后等待 60 秒检查变化。首次导入较慢，逐文件完成并保存清单，失败重试。每个文件使用稳定 document_id，修改时删除旧索引后重建；文件删除也删除索引。同步范围是显式白名单，不是自动扫描全部工作区。

每个 Pi operational turn 在 `before_agent_start` 自动召回个人与 Com bank，以 `com-memory` 历史上下文注入；Pi 也可调用只读 `memory_recall`。召回只接受带来源路径与 SHA256、且对应当前原文件版本的事实；索引过期、文件被删除或未经 Markdown 同步的事实不注入。关闭自动 consolidation，衍生 observation 不参与召回，避免丢失来源与版本。重排序相关性低于 0.03 的结果丢弃，最多注入 8 条。单文件导入失败不会阻断其他文件，下轮重试失败文档。自动查询使用当前用户正文，剥离 Com 传输元信息；模型上下文仅保留本轮注入的记忆，旧轮索引摘要仍留在会话审计档案，但不作为新轮记忆上下文发送。每轮状态与耗时记录在 `com-memory-status` 内部条目中，不记录原文或凭据。

记忆不授予新操作权限，也不保证实时状态正确；动态事实应回读权威原文并现场核验。服务超时最多约 8 秒，不中断聊天。未查询成功返回 unavailable/partial，不声称没有历史记忆。

## 写入与提炼

用户要求“记下”时由 Agent 先写合适的工作区 Markdown，再由同步器摄入；没有提供模型直接写 Hindsight 的 retain 工具，也不自动把每轮对话存进去。

在 mini 项目 backend 目录：

```sh
~/.session-workbench/venv/bin/python memory.py recall '上次 Com 的重试策略是什么'
~/.session-workbench/venv/bin/python memory.py sync
~/.session-workbench/venv/bin/python memory.py reflect '归纳 Com 的架构决策' --bank project-com
```

reflect 将结果保存为 `docs/memory-reflections/` 的 Markdown 草稿，明确标识模型推断，默认不重新摄入。核对引用与事实后可人工整理到正式资料，避免自我强化。不要把提炼草稿当成已经确认的档案。

## 检查和恢复

```sh
curl http://127.0.0.1:8888/health
launchctl print gui/$(id -u)/work.eddie.com-memory
launchctl print gui/$(id -u)/work.eddie.com-memory-sync
```

清单：`~/.com-memory/manifest.json`；日志：`~/.com-memory/work.eddie.com-memory*.log`。

停止索引与召回服务可 bootout 两个新 LaunchAgent，原 Markdown 与 Com 的普通聊天不依赖它们。重建仅删除专属 bank 的索引和清单，然后重新同步；不要删除权威 Markdown。源码安装入口：`backend/install-memory-mini.py`。依赖固定为 `hindsight-api==0.10.2`。

## 2026-10-05 部署验收

- mini Hindsight `/health`：healthy / database connected；两个新 launchd 服务为 running。
- Com `/health` 已声明 `markdown_hindsight_memory_v1`；认证的 `/personal/memory` 返回索引覆盖状态。
- 临时原生 Pi 会话自动注入 `com-memory`，完成回答并指出核心身份 Markdown 来源；未使用生产聊天会话。
- 实际独立验收 bank 完成 retain、稳定文档替换、recall、删除；旧颜色事实消失，删除后文档与事实数量归零；验收 bank 随后移除。
- reflect 已生成 `memory-reflections/` 草稿并检查正文；草稿不重新摄入。
- 记忆模块、Pi 合约/安全路径与 API 的相关检查通过；原有其他工作区改动保留。
- 首次全量索引由常驻同步器持续处理；实时数量以 `/personal/memory` 为准，未完成首次导入的文件暂时不会参与召回。

实现依据：[Hindsight 官方源码与部署说明](https://github.com/vectorize-io/hindsight)。
