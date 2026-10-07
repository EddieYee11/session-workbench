"""Collect local session excerpts. Optional --push-mini uses existing SSH, no native credential copying."""
import argparse,json,subprocess,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
from project_board import collect,ProjectBoard
p=argparse.ArgumentParser();p.add_argument('--host',choices=['macbook','mini'],default='macbook');p.add_argument('--push-mini',action='store_true');p.add_argument('--ingest',action='store_true');args=p.parse_args()
state=Path.home()/'.session-workbench'
if args.ingest:
    print(json.dumps(ProjectBoard(state).ingest(json.load(sys.stdin))));raise SystemExit()
data=collect(Path.home(),state,args.host)
if args.push_mini:
    command='cd "$HOME/AI_Work_System/work/工具与效率/会话工作台" && "$HOME/.session-workbench/venv/bin/python" backend/probes/export_project_board.py --ingest'
    result=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10','mini',command],input=json.dumps(data,ensure_ascii=False),text=True,capture_output=True,timeout=60)
    if result.returncode:raise SystemExit('项目快照发送失败，下次重试')
    print(result.stdout.strip())
else:print(json.dumps(data,ensure_ascii=False))
