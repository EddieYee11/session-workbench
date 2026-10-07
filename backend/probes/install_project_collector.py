"""Install the user's MacBook session-board exporter using the existing mini SSH alias."""
import os,plistlib,subprocess,sys
from pathlib import Path
home=Path.home();repo=Path(__file__).resolve().parents[2]
label='work.eddie.com.project-collector'
folder=home/'Library/LaunchAgents';folder.mkdir(exist_ok=True)
logs=home/'.session-workbench/logs';logs.mkdir(parents=True,exist_ok=True)
p=folder/(label+'.plist')
value={'Label':label,'ProgramArguments':[sys.executable,str(repo/'backend/probes/export_project_board.py'),'--host','macbook','--push-mini'],
       'WorkingDirectory':str(repo),'RunAtLoad':True,'StartInterval':600,'ProcessType':'Background',
       'EnvironmentVariables':{'PATH':'/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'},
       'StandardOutPath':str(logs/'project-collector.log'),'StandardErrorPath':str(logs/'project-collector-error.log')}
if p.exists() and p.read_bytes()!=plistlib.dumps(value):
    backup=logs/'project-collector.previous.plist';backup.write_bytes(p.read_bytes())
subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}/{label}'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
p.write_bytes(plistlib.dumps(value));p.chmod(0o600)
subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(p)],check=True)
print('已安装 MacBook 项目快照任务：每10分钟，联网时通过既有 mini SSH 通道发送。')
