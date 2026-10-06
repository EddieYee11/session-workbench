# 雷鸟 iO → Com! 眼镜入口

2026-10-04 实现。沿用 Turbo-IO 的官方 ASR / 普通问答模板 / NLP 回显，不替换蓝牙协议，不要求实验固件，不经过 Muse 或 Dashboard 卡片审批。

```text
眼镜当前对话（所有 NLP 意图） → 雷鸟宿主 + Turbo-IO 扩展
  → HTTPS /sessions/rayneo/v1/chat/completions
  → Com! 主对话统一请求登记 → 原生 Pi → 现有业务工具
  → 对应请求回执 → OpenAI 格式 SSE → 原问答回调 → 镜片
```

## 手机入口

Turbo IO → 模型与对话 →「Com! · 配对与请求回执」。填写服务地址及一次性配对码，点击配对。默认地址为 `https://pi.eddiegao.work:8443/sessions/rayneo/v1`。

配对成功后启用自有模型 `com-personal`。眼镜令牌使用 Android Keystore 加密保存，APK 不含令牌。03版打开配对页时会关闭原模型设置弹窗，避免旧页面覆盖新配对设置。

“检查真实服务连接”请求实际服务。“发送新消息”进入真实 Com! 主对话；每次点击产生新请求。“查询上次回执”只读；“重连上次请求”沿用原文字及请求标识，不重复交办。这些手机按钮用于诊断，不能代替眼镜实际回显验收。

## 服务端

新增 `backend/rayneo.py`，路由在已有 Com! FastAPI 内运行，继续使用 Mac mini 的 `work.eddie.sessions` launchd 服务及现有 Caddy `/sessions/*` 转发。无新增常驻 Bridge 进程。旧 Muse Bridge 保留原状，可用于后续实验。

| 接口 | 用途 |
|---|---|
| `POST /rayneo/v1/pair` | 限时、单次配对码换取专用令牌 |
| `GET /rayneo/v1/health` | 验证专用权限和服务连接 |
| `POST /rayneo/v1/chat/completions` | 稳定 request_id、com-personal、stream=true |
| `GET /rayneo/v1/receipts/{request_id}` | 只读查询本入口登记的请求与结果 |

专用令牌位于服务主机 `~/.session-workbench/rayneo-token`（0600），不能访问主聊天、任务或内部 Agent API。生成新的配对码时在 mini 执行下面的命令；只将一次性配对码输入手机，不复制主连接令牌：

```sh
python3 - <<'PY'
from pathlib import Path
import json,secrets,time
code=secrets.token_hex(4)
p=Path.home()/'.session-workbench/rayneo-pairing.json'
p.write_text(json.dumps({'code':code,'expires':time.time()+600}))
p.chmod(0o600)
print('十分钟内使用的一次性配对码：',code)
PY
```

配对码成功使用后删除；失败次数有短期上限。配对接口仅返回眼镜专用令牌。令牌文件及配对码不能提交仓库、写入记忆或打入安装包。

## 请求与执行语义

- 只将消息列表最后一条用户话语提交到 Com!，插件历史不重放。
- 主对话 SQLite 的 `rayneo_requests` 表登记真实来源，统一语音与主对话负责实际请求去重。相同 ID / 相同文字返回原结果；ID 与文字冲突拒绝。
- 两次新语音即使金额与文字完全相同，也分别处理。去重依据请求标识，不能按文字或最近账目猜重复。
- 04版按用户明确授权采用与 Com! 主对话相同的 Full access：原生 Shell、文件操作、任务及已接入的个人工具可用，不按眼镜来源另设工具白名单。真实来源、重复操作保护及主对话既有的不可逆操作流程共用。
- 同一请求的相同工具及参数沿主对话执行记录去重；允许真实指令要求的多笔消费、多次不同操作。
- 镜片先收到“已受理，处理中”；保持 SSE 连接期间发送保活。账本新增记录必须取得原生工具写入凭据，并随后回查匹配 ID、金额、类别和备注，才能显示“已记 ¥金额 · 用途 · #ID”。助手文字不能冒充写入成功。
- 后续按用户实机反馈开放原生 `remind add/list`（微信 direct 提醒）与 `calendar_event create/list_calendars`。提醒成功需要原生创建回执及 list 回查新ID；日历成功需要原生脚本返回创建成功。微信提醒投递沿已有 Pi 网关，不增加新的提醒服务。
- Com! 模型开启时，当前 ASR 对话的所有 NLP 意图交给 Com!，保持本轮所有权，后续官方回调不会另执行官方待办。回显保留会话标识，清除官方 command/rawData 并规范为聊天载荷。其他模型保留原路由。
- 显示连接断开不会取消或重放业务。80秒内未取得终态时提示仍在处理及不要重复记账；原请求继续可查。失败或未知状态不能显示成功。

## 验证与当前边界

验收记录见 `verification/rayneo-20261004/`。真实软件验证包括公开 HTTPS、主对话 / 原生 Pi、手机配对 / 收到验证码、同请求重连、专用令牌隔离，以及原生 Pi + 原记账工具的临时账本新增 / 回查 / 同文字两笔 / 断线恢复。临时账本使用独立 Com! 状态和原工具代码的独立配置副本，不改生产账本配置。

04版已取消普通聊天意图限制；已安装 APK 与构建文件 SHA-256 一致。已取得真实眼镜语音、Pi 回答、镜片显示、手机熄屏连续追问和移动网络回显的用户确认；眼镜买水2元指令已完成生产账本写入及回查，等待该笔镜片结果确认，详见 `../verification/rayneo-20261004/验收记录.md`。全天智记长时间并行与所有官方功能回归仍需分别记录硬件证据。Full access 表示允许调用已有工具，不表示未接入的工具或硬件能力已实现或验收。

## 速度与上下文补充

每轮任务信息缩为身份与状态，避免反复追加历史工程正文；原生 Pi 上下文超过180000 token时采用原生压缩，保留真实对话及未完成事项，禁止重放历史操作。已测上下文801287→23710 token。压缩一次约37秒，正常热请求测试见 `../verification/rayneo-20261004/latency-after.json`。

金额短答可关联紧邻的待确认记账请求，保留两轮真实来源，以最后确认金额为准。没有待确认事项、查询、否定、引用、过期问题和已执行事项均不产生新增账目。详细复现见验收记录。

## 回滚

手机构建保持本机 Android 开发签名，可覆盖前次本机签名包。原厂 APK 与开发签名不同，恢复原厂需处理签名冲突及 App 数据。上一次完整构建及原厂输入均保留于 Turbo-IO 本地目录。

服务端上线前已核验无活动主对话和工作器，并备份 SQLite 到 mini 的 `~/.session-workbench/backups/rayneo-20261004/`。原有三个源文件基线副本位于 `verification/rayneo-20261004/rollback/`。撤回入口只移除本次路由及执行范围校验；已登记请求和业务回执应保留用于核实，不重放。
