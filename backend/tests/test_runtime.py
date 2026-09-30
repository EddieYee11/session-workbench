import asyncio,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from runtime import Runtime
from history import History

def test_pi_process_title_without_arguments_keeps_unknown_history_readonly(tmp_path):
 h=History(tmp_path,tmp_path/'state');r=Runtime(h,'test')
 async def command(*args,**kwargs):return '123 pi\n456 /bin/zsh'
 r.cmd=command
 assert not asyncio.run(r.resumable({'id':'pi:old','agent':'pi','native_id':'old','cwd':str(tmp_path)}))
 async def empty(*args,**kwargs):return '456 /bin/zsh'
 r.cmd=empty
 assert asyncio.run(r.resumable({'id':'pi:old','agent':'pi','native_id':'old','cwd':str(tmp_path)}))
