#!/usr/bin/env python3
"""把手机登记的 SSH 公钥装进 MBP 和 mini 的 authorized_keys，并写手机专用的 herdr 配置。在 MBP 上手动运行。

公钥来源：mini 的 ~/.session-workbench/herdr-device-keys.json；也可用 --key '<公钥行>' 直接指定。
restrict,pty 关掉转发能力，只留终端；mini 是外网入口，额外只放行到 MBP 反向隧道的那一个端口。
MBP 隧道见同目录 work.eddie.herdr-mbp-tunnel.plist（放进 ~/Library/LaunchAgents）。
"""
import argparse
import json
import pathlib
import shlex
import subprocess

OPTIONS = "restrict,pty"
MINI_OPTIONS = 'restrict,pty,port-forwarding,permitopen="127.0.0.1:22222"'
# 手机版配置 = 该机现有配置 + 始终用手机布局，宽度再大也不显示左侧栏。桌面端不读这个文件。
PHONE_CONFIG = r"""
import pathlib, re
base = pathlib.Path.home() / ".config/herdr"
text = (base / "config.toml").read_text() if (base / "config.toml").exists() else ""
text = re.sub(r"^\s*mobile_width_threshold\s*=.*\n?", "", text, flags=re.M)
line = "mobile_width_threshold = 1000\n"
if re.search(r"^\[ui\]\s*$", text, flags=re.M):
    text = re.sub(r"^\[ui\]\s*$", "[ui]\n" + line.rstrip(), text, count=1, flags=re.M)
else:
    text = text.rstrip() + "\n\n[ui]\n" + line
(base / "config-com-phone.toml").write_text(text)
"""


def line_for(key, options=OPTIONS):
    return f"{options} {key}"


def install_local(keys):
    path = pathlib.Path.home() / ".ssh" / "authorized_keys"
    existing = path.read_text() if path.exists() else ""
    added = [k for k in keys if k.split()[1] not in existing]
    if added:
        with path.open("a") as handle:
            if existing and not existing.endswith("\n"):
                handle.write("\n")
            handle.writelines(line_for(k) + "\n" for k in added)
    return len(added)


def install_mini(keys):
    added = 0
    for key in keys:
        body = key.split()[1]
        # 已有的旧权限行也换成当前这行。
        script = (
            f"grep -qF {shlex.quote(line_for(key, MINI_OPTIONS))} ~/.ssh/authorized_keys || {{ "
            f"grep -vF {shlex.quote(body)} ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp; "
            f"echo {shlex.quote(line_for(key, MINI_OPTIONS))} >> ~/.ssh/authorized_keys.tmp; "
            f"mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys; echo added; }}"
        )
        out = subprocess.run(["ssh", "mini", script], check=True, capture_output=True, text=True).stdout
        added += "added" in out
    return added


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--key", action="append", default=[], help="直接指定公钥行，可重复")
    args = parser.parse_args()
    keys = args.key
    if not keys:
        raw = subprocess.run(
            ["ssh", "mini", "cat ~/.session-workbench/herdr-device-keys.json"],
            check=True, capture_output=True, text=True,
        ).stdout
        keys = json.loads(raw)
    subprocess.run(["python3", "-c", PHONE_CONFIG], check=True)
    subprocess.run(["ssh", "mini", "python3 -c " + shlex.quote(PHONE_CONFIG)], check=True)
    print(f"公钥 {len(keys)} 把；MBP 新增 {install_local(keys)}，mini 新增 {install_mini(keys)}")


if __name__ == "__main__":
    main()
