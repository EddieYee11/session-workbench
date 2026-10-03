# B6 秘密管理审计与提案（未实施）

2026-10-03 在 Mac mini 只检查路径、权限及调用代码，没有读取或输出凭据值。

| 当前保管/使用处 | 现场权限、边界 |
|---|---|
| ~/.pi/agent/auth.json | 0600；Pi/ModelRuntime 原生读取提供商认证；Com 心跳调用同一已有 runtime，摘要不含凭据 |
| ~/.codex/auth.json | 0600；Codex 原生认证，Com 通过 app-server 协议访问 |
| ~/.claude/.credentials.json | 0600；原生认证存在；Com 第三方 Claude 另从 agent-config/env 解析供应商配置，不能认作相同认证路径 |
| ~/.session-workbench/agent-config.json 与进程环境 | backend/claude_worker.py third_party_config 合并 ANTHROPIC_*；传子进程 env，不加入提示词；agent-config.json 现场为0600 |
| ~/.session-workbench/token | 0600；API 配对授权，Android Store 加密保管；不加入模型用户正文 |
| ~/.pi-gateway/.env | 0600；既有网关持有业务凭据，与 Com 原生会话独立 |

代码审计：PiRPC 不保存原始 stderr，只记固定诊断标签；但原生 tool 结果、用户正文、task 事件与部分 Runtime.cmd 错误可能进入持久记录。完整权限下模型也可能通过 read/bash 读取秘密。没有扫描所有历史日志、备份与所有第三方输出，不能声明“从未泄漏”或“已彻底脱敏”。当前提示词要求不读取/展示凭据是协作规则，不是系统访问控制。

建议独立保管处（优先 macOS Keychain 或现有成熟 Vault），模型只获得 service/account/secret_ref 占位符。用户对具体账户与用途授权后，由请求执行边界解析并注入 header/env；返回只含结果与脱敏诊断。HTTP、子进程、工具结果、事件日志和调试导出统一脱敏，授权有期限并可撤销；不得把私钥或解密后的秘密回传模型。需要审计授权/调用对象/时间/结果，不记密钥值。

与完整权限策略的关系：目的是减少密钥进入模型上下文和日志，不是限制 Agent；同用户权限的 Agent 仍可能访问保管处或注入进程。若要保证它不能读取，必须另外设计真正隔离的执行边界，那是新架构和新授权，不能宣称本方案已提供。

分步实施建议：先凭据清单与输出脱敏测试，再选一个无财务副作用服务做占位符试点；保留现有原生认证可回滚。需用户决定保管产品、授权有效期与支持的服务。本轮不迁移密钥、不变更认证、不写 Vault、不启用新功能。
