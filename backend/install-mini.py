"""Run on Mac mini after Syncthing delivers this project. Idempotent isolated install."""
import json,os,plistlib,subprocess,time
from pathlib import Path
h=Path.home();state=h/'.session-workbench';state.mkdir(exist_ok=True);state.chmod(0o700)
root=Path(__file__).resolve().parent
python=str(state/'venv/bin/python')
subprocess.run([python,'-m','pip','install','-q','-r',str(root/'requirements.txt')],check=True)
plist={'Label':'work.eddie.sessions','ProgramArguments':[python,'-m','uvicorn','app:app','--host','127.0.0.1','--port','8650','--no-access-log'],'WorkingDirectory':str(root),'EnvironmentVariables':{'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin','WORKBENCH_STATE':str(state)},'RunAtLoad':True,'KeepAlive':True,'StandardOutPath':str(state/'stdout.log'),'StandardErrorPath':str(state/'stderr.log')}
p=h/'Library/LaunchAgents/work.eddie.sessions.plist'
if p.exists():
 subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(p)],capture_output=True)
p.write_bytes(plistlib.dumps(plist));subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(p)],check=True)
caddy=h/'.pi-gateway/caddy/Caddyfile';text=caddy.read_text()
marker='\t# Mini Sessions standalone app\n'
if marker not in text:
 backup=state/('Caddyfile.before-'+str(int(time.time())));backup.write_text(text);backup.chmod(0o600)
 candidate=text.replace('\t# Pi Dashboard routes',marker+'\thandle_path /sessions/* {\n\t\treverse_proxy 127.0.0.1:8650\n\t}\n\t# Pi Dashboard routes',1)
 if candidate==text:raise RuntimeError('未找到预期的 Caddy 插入位置')
 temporary=state/'Caddyfile.next';temporary.write_text(candidate);temporary.chmod(0o600)
 checked=subprocess.run(['/opt/homebrew/bin/caddy','validate','--config',str(temporary),'--adapter','caddyfile'],capture_output=True)
 if checked.returncode:raise RuntimeError('Caddy 验证失败；原配置保持不变')
 caddy.write_text(candidate)
 loaded=subprocess.run(['/opt/homebrew/bin/caddy','reload','--config',str(caddy),'--adapter','caddyfile'],capture_output=True)
 if loaded.returncode:caddy.write_text(text);raise RuntimeError('Caddy 加载失败，已恢复原文件')
print('Installed independent service on localhost:8650; HTTPS /sessions route ready.')
