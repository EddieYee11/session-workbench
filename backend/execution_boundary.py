"""Host and filesystem boundaries for Com-managed project writes."""
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
    rules=' '.join('(subpath '+json.dumps(path)+')' for path in writable)
    profile='(version 1) (allow default) (deny file-write*) (allow file-write* '+rules+')'
    return ['/usr/bin/sandbox-exec','-p',profile,*argv]
