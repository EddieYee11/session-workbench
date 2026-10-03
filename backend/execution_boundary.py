"""Host checks and opt-in boundaries for isolated probes and tool-free judges.

Operational Com workers run full access and do not select this sandbox.
"""
import json
import socket
import sys
from pathlib import Path


def require_host(state):
    config=Path(state)/'agent-config.json'
    expected=json.loads(config.read_text()).get('execution_host') if config.exists() else None
    if expected and socket.gethostname()!=expected:
        raise ValueError('受管写操作仅在已配置的 mini 执行；当前主机不匹配')


def sandbox(argv,state,root,readonly=False):
    if sys.platform!='darwin':
        raise ValueError('当前主机缺少已验证的文件写隔离，暂停执行')
    import tempfile
    writable=[str(Path(state).resolve()),str(Path(tempfile.gettempdir()).resolve()),'/private/tmp','/dev/null']
    if not readonly:writable.append(str(Path(root).resolve()))
    rules=' '.join('(subpath '+json.dumps(path,ensure_ascii=False)+')' for path in writable)
    # Native Pi reads shared auth through proper-lockfile. Permit only that
    # lock directory's metadata lifecycle, never auth.json or global config.
    auth_lock=Path.home()/'.pi/agent/auth.json.lock'
    locks=sorted({str(auth_lock),str(auth_lock.resolve())})
    lock_rules=' '.join('(subpath '+json.dumps(path,ensure_ascii=False)+')' for path in locks)
    profile=('(version 1) (allow default) (deny file-write*) (allow file-write* '+rules+')'
             # Darwin's directory utimes checks more than file-write-times.
             # Only the auth lock namespace receives its lifecycle operations.
             ' (allow file-write* '+lock_rules+')')
    return ['/usr/bin/sandbox-exec','-p',profile,*argv]
