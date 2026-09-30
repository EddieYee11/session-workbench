"""Run on Mac mini to replace the one-time pairing code. Never prints the service token."""
import json,os,secrets,time
from pathlib import Path
state=Path(os.environ.get('WORKBENCH_STATE',str(Path.home()/'.session-workbench')))
state.mkdir(exist_ok=True,parents=True);state.chmod(0o700)
code='-'.join(secrets.token_hex(2) for _ in range(3))
p=state/'pairing.json';p.write_text(json.dumps({'code':code,'expires':time.time()+600}));p.chmod(0o600)
print('配对码（10 分钟有效，使用一次后失效）：'+code)
