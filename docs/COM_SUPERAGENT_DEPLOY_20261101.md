# Com Super-agent 部署与回滚（2026-11-01）

## 开关（mini，不进仓库）

`~/.session-workbench/superagent-flags.json`：

```json
{"router":"off","mandate":"off","herdr_write":"off"}
```

建议顺序：`mandate=shadow` → 抽查 → `on`；再 `router=on`；最后 `herdr_write=on`。

## Herdr 双机

- mini：`COM_HOST_LABEL=mini` 写入 `work.eddie.sessions` launchd（避免 host 显示成 `192`）。
- MBP：配置 `COM_HERDR_INGEST_URL` 指向可达的 mini:8650（局域网或 `ssh -L 8650:127.0.0.1:8650 mini`），token 文件可读；周期性跑 `backend/herdr_push/mbp_herdr_agent.py`。
- **不要**在 mini 上开通到 MBP 的交互 SSH。

## 部署

1. 提交排除 `backend/tmp_add_todo.py`、`最新3份文档概览.md`。
2. Syncthing 对齐后，对关键 `.py` 做 MBP↔mini md5 比对。
3. 有 Pi 子进程在跑 → 推迟 `kickstart`；否则：
   `launchctl kickstart -k gui/$(id -u)/work.eddie.sessions`
4. 版本真源 = 文件 md5 / git commit，**不要**看 `/health` 里可能陈旧的 git 短哈希。

## 回滚

1. 三开关全 `off`（功能立即停）。
2. 需要代码回滚：记下部署前 commit，Syncthing 拉回旧文件后再 kickstart。
3. `triggers.sqlite` / `mandates.sqlite` / `batches.sqlite` / `herdr-actions.sqlite` 可保留；关开关即不再写业务面。

## Watchdog

`backend/watchdog_superagent.py`：有 Pi 子进程只告警；仅当 `WATCHDOG_ALLOW_KICKSTART=1` 才 kickstart。
