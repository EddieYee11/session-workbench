#!/usr/bin/env python3
"""MBP 接单程序：挂在 mini 上等活，一次最长 50 秒，有活立刻领走。

只认 worker_queue.KINDS 里写死的活。mini 不用连进 MBP，MBP 也不用暴露端口。
地址和 token 读 ~/.config/com-worker.json：{"base_url": "http://127.0.0.1:18650", "token": "..."}（600 权限，不进仓库）；
端口由 work.eddie.com-worker-tunnel 经 ssh mini 转发，外网也通。
"""
import json, ssl, subprocess, sys, time, urllib.error, urllib.request
from pathlib import Path

CONFIG = Path.home() / '.config/com-worker.json'
PI_DELEGATE = Path.home() / 'AI_Work_System/tools/pi_delegate.sh'
MACHINE = 'mbp'
JOB_TIMEOUT = 600


def request(config, path, body=None, timeout=70):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(config['base_url'].rstrip('/') + path, data=data, method='POST' if body is not None else 'GET',
                                 headers={'Authorization': 'Bearer ' + config['token'], 'Content-Type': 'application/json'})
    # 直连 mini，不走本机代理。
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    with opener.open(req, timeout=timeout) as response:
        return json.load(response)


def run(job):
    if job['kind'] == 'ping':
        return True, 'pong ' + time.strftime('%Y-%m-%d %H:%M:%S')
    if job['kind'] == 'pi_readonly':
        done = subprocess.run(['/bin/zsh', str(PI_DELEGATE), job['prompt']], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=JOB_TIMEOUT)
        return done.returncode == 0, (done.stdout + done.stderr)[-20000:]
    return False, '不支持的活：' + str(job['kind'])


def main():
    config = json.loads(CONFIG.read_text())
    while True:
        try:
            job = request(config, f'/workers/{MACHINE}/claim?wait=50').get('job')
            if not job:
                continue
            try:
                ok, result = run(job)
            except Exception as error:
                ok, result = False, f'{type(error).__name__}: {error}'
            request(config, f"/workers/{MACHINE}/jobs/{job['id']}/result", {'ok': ok, 'result': result}, timeout=30)
        except (urllib.error.URLError, OSError, ValueError) as error:
            # mini 重启、MBP 睡醒断网都走这里；等一下接着挂。
            print(f'{time.strftime("%H:%M:%S")} {type(error).__name__}: {error}', file=sys.stderr, flush=True)
            time.sleep(15)


if __name__ == '__main__':
    main()
