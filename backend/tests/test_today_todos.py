"""今天页待办打勾 / 撤销（轨道 r3-pages）：只动「状态 / 完成时间」两行，撤销逐字节还原，路径只认 `任务/待处理/`。"""
import os,sys,time
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from today import Today

NOW=time.mktime((2026,10,10,9,30,0,0,0,-1))
BODY='\n# 八月打车报销\n\n## 说明\n\n状态: 这一行在正文里，不是属性，不能动。\n完成时间: 正文里的也不能动\n'
TEMPLATE='---\nflow: 任务\n状态: 待处理\n关联项目: "[[合同与劳务结算]]"\n计划开始: \n计划结束: 2026-10-09\n完成时间:\n下一步: 跑 invoice_reconcile 后提交\ncreated: 2026-10-05\n---\n'+BODY

def vault(tmp_path,name='八月打车报销',text=TEMPLATE,newline='\n'):
    folder=tmp_path/'任务'/'待处理';folder.mkdir(parents=True,exist_ok=True)
    (tmp_path/'任务'/'已完成').mkdir(exist_ok=True)
    path=folder/f'{name}.md'
    path.write_bytes(text.replace('\n',newline).encode('utf-8'))
    return Today(vault=tmp_path,clock=lambda:NOW),path,f'任务/待处理/{name}.md'

def head(path):return path.read_text(encoding='utf-8').split('---\n')[1]

def test_done_sets_state_and_date_and_today_drops_it(tmp_path):
    today,path,rel=vault(tmp_path)
    assert [t['title'] for t in today.snapshot()['todos']]==['八月打车报销']
    before=path.read_bytes()
    r=today.todo_done(rel)
    assert r['changed'] and r['completed_at']=='2026-10-10'
    assert r['undo']=={'状态':'状态: 待处理','完成时间':'完成时间:'}
    lines=head(path).splitlines()
    assert '状态: 已完成' in lines and '完成时间: 2026-10-10' in lines
    # 正文和其他字段一个字节不动：只有两行变了，行数不变
    old,new=before.decode().splitlines(),path.read_text(encoding='utf-8').splitlines()
    assert len(old)==len(new) and [i for i,(a,b) in enumerate(zip(old,new)) if a!=b]==[2,6]
    assert path.read_text(encoding='utf-8').endswith(BODY)
    assert today.snapshot()['todos']==[],'打完勾立刻从今天的待办里消失'
    assert not list(path.parent.glob('.*')),'没有留下临时文件'

def test_done_twice_is_idempotent(tmp_path):
    today,path,rel=vault(tmp_path)
    first=today.todo_done(rel);after=path.read_bytes()
    again=today.todo_done(rel)
    assert again['changed'] is False and again['undo'] is None
    assert path.read_bytes()==after
    today.todo_undo(rel,first['undo'])
    assert path.read_bytes()==TEMPLATE.encode('utf-8')

@pytest.mark.parametrize('text,newline',[
    (TEMPLATE,'\n'),
    (TEMPLATE,'\r\n'),
    (TEMPLATE.replace('完成时间:\n',''),'\n'),                          # 原来没有完成时间：撤销时删掉新加的那行
    (TEMPLATE.replace('状态: 待处理\n','').replace('完成时间:\n',''),'\n'),  # 两行都没有（状态缺省就是待处理）
    (TEMPLATE.replace('状态: 待处理','状态: "待处理"').replace('完成时间:','完成时间: 2026-09-30'),'\n'),
])
def test_undo_restores_exact_bytes(tmp_path,text,newline):
    today,path,rel=vault(tmp_path,text=text,newline=newline)
    original=path.read_bytes()
    r=today.todo_done(rel)
    assert r['changed'] and path.read_bytes()!=original
    assert b'\xe5\xb7\xb2\xe5\xae\x8c\xe6\x88\x90' in path.read_bytes()  # 已完成
    if newline=='\r\n':assert b'\n' not in path.read_bytes().replace(b'\r\n',b''),'新写的行也用 CRLF'
    u=today.todo_undo(rel,r['undo'])
    assert u['changed'] and u['path']==rel
    assert path.read_bytes()==original
    assert [t['title'] for t in today.snapshot()['todos']]==['八月打车报销']
    assert today.todo_undo(rel,r['undo'])['changed'] is False,'重复撤销不再改'

def test_undo_after_auto_move_restores_in_place(tmp_path):
    today,path,rel=vault(tmp_path)
    original=path.read_bytes()
    r=today.todo_done(rel)
    moved=tmp_path/'任务'/'已完成'/path.name
    os.replace(path,moved)  # Obsidian 的 auto-move 插件按「已完成」挪走了
    u=today.todo_undo(rel,r['undo'])
    assert u['path']=='任务/已完成/八月打车报销.md' and moved.read_bytes()==original
    assert not path.exists(),'不自己挪文件，插件会按「待处理」挪回去'

def test_undo_refuses_when_state_changed_elsewhere(tmp_path):
    today,path,rel=vault(tmp_path)
    r=today.todo_done(rel)
    path.write_text(path.read_text(encoding='utf-8').replace('状态: 已完成','状态: 进行中'),encoding='utf-8')
    with pytest.raises(ValueError,match='别处改过'):today.todo_undo(rel,r['undo'])
    for bad in (None,{},{'状态':'状态: 待处理'},{'状态':'备注: x','完成时间':None},{'状态':'状态: 待处理\n备注: 注入','完成时间':None}):
        with pytest.raises(ValueError):today.todo_undo(rel,bad)

def test_rejects_paths_outside_pending(tmp_path):
    today,path,rel=vault(tmp_path)
    secret=tmp_path/'secret.md';secret.write_text('---\n状态: 待处理\n---\n',encoding='utf-8')
    done=tmp_path/'任务'/'已完成'/'旧的.md';done.write_text('---\n状态: 待处理\n---\n',encoding='utf-8')
    sub=tmp_path/'任务'/'待处理'/'子目录';sub.mkdir();(sub/'深一层.md').write_text('---\n状态: 待处理\n---\n',encoding='utf-8')
    (tmp_path/'任务'/'待处理'/'软链接.md').symlink_to(secret)
    (tmp_path/'任务'/'待处理'/'说明.txt').write_text('x',encoding='utf-8')
    for bad in ('../secret.md','任务/待处理/../../secret.md',str(secret),'任务/已完成/旧的.md','任务/待处理/子目录/深一层.md',
                '任务/待处理/软链接.md','任务/待处理/说明.txt','任务/待处理/00-任务索引.md','任务/待处理/不存在.md','',None,'任务/待处理/\x00.md'):
        with pytest.raises(ValueError):today.todo_done(bad)
    assert secret.read_text(encoding='utf-8')=='---\n状态: 待处理\n---\n' and done.read_text(encoding='utf-8')=='---\n状态: 待处理\n---\n'
    with pytest.raises(ValueError):Today(vault=None).todo_done(rel)

def test_todo_endpoints_use_configured_vault(tmp_path,monkeypatch):
    import importlib
    from fastapi.testclient import TestClient
    monkeypatch.setenv('WORKBENCH_HOME',str(tmp_path));monkeypatch.setenv('WORKBENCH_STATE',str(tmp_path/'state'))
    root=tmp_path/'Library'/'Mobile Documents'/'iCloud~md~obsidian'/'Documents'/'obsidian'
    _,path,rel=vault(root)
    original=path.read_bytes()
    import app
    app=importlib.reload(app)
    auth={'Authorization':'Bearer '+app.TOKEN}
    with TestClient(app.app) as c:
        r=c.post('/personal/today/todos/done',json={'path':rel,'request_id':'r3-done-0001'},headers=auth)
        assert r.status_code==200 and r.json()['changed'] and '状态: 已完成' in path.read_text(encoding='utf-8')
        u=c.post('/personal/today/todos/undo',json={'path':rel,'undo':r.json()['undo'],'request_id':'r3-undo-0001'},headers=auth)
        assert u.status_code==200 and path.read_bytes()==original
        bad=c.post('/personal/today/todos/done',json={'path':'../../../../.ssh/id_rsa'},headers=auth)
        assert bad.status_code==409 and '待处理' in bad.json()['detail']
        assert c.post('/personal/today/todos/done',json={'path':rel}).status_code==401
