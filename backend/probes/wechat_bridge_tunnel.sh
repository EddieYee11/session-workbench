#!/bin/zsh
# MBP → mini 的 SSH 反向隧道：mini 的 127.0.0.1:18771 转发到本机 18771（微信查询桥）。
# 只绑两端的 loopback；Mini 侧 sshd 默认允许 -R。断线由 launchd + 本循环双层重连。
while true; do
  ssh -N \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=20 \
    -o ServerAliveCountMax=3 \
    -o ConnectTimeout=10 \
    -R 18771:127.0.0.1:18771 mini
  echo "[$(date '+%F %T')] 隧道断开，5 秒后重连"
  sleep 5
done
