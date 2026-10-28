#!/bin/zsh
# 微信查询桥的进程管理：查询服务 + SSH 反向隧道，任一退出就整体重启（launchd KeepAlive 兜底）。
# 由 com.eddie.wechat-bridge.plist 拉起，日志写在 ~/.session-workbench/logs/wechat-bridge.log。
# 注意：macOS 自带 bash 3.2 / zsh 都没有 `wait -n`，所以用轮询看子进程是否还活着。
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="$HOME/wechat-decrypt/venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"

cleanup() { kill "$bridge" "$tunnel" 2>/dev/null; }
trap cleanup EXIT INT TERM

"$PY" "$ROOT/backend/probes/wechat_bridge.py" &
bridge=$!
zsh "$ROOT/backend/probes/wechat_bridge_tunnel.sh" &
tunnel=$!

while kill -0 "$bridge" 2>/dev/null && kill -0 "$tunnel" 2>/dev/null; do
  sleep 5
done

echo "[$(date '+%F %T')] 子进程退出，整体重启"
cleanup
