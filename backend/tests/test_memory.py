import asyncio
from pathlib import Path
import memory


def setup_sources(tmp_path, monkeypatch):
    root=tmp_path/'workspace'; state=tmp_path/'state'
    folder=root/'_global/本体画像'; folder.mkdir(parents=True)
    source=folder/'00-核心身份.md'; source.write_text('喜欢中文与可验证结果')
    monkeypatch.setattr(memory,'ROOT',root)
    return root,state,source


def test_update_delete_and_retry(tmp_path,monkeypatch):
    root,state,source=setup_sources(tmp_path,monkeypatch)
    calls=[]
    async def request(method,bank,suffix='',body=None,timeout=8):
        calls.append((method,bank,suffix,body)); return {}
    monkeypatch.setattr(memory,'request',request)
    assert asyncio.run(memory.sync_once(root,state))['changed']==1
    assert asyncio.run(memory.sync_once(root,state))['changed']==0
    first=calls[-1][3]['items'][0]['document_id']
    source.write_text('现在需要完整验证')
    asyncio.run(memory.sync_once(root,state))
    assert calls[-2][0]=='DELETE'
    assert calls[-1][3]['items'][0]['document_id']==first
    source.unlink(); asyncio.run(memory.sync_once(root,state))
    assert calls[-1][0]=='DELETE'
    assert asyncio.run(memory.sync_once(root,state))['documents']==0


def test_stale_and_untracked_results_never_injected(tmp_path,monkeypatch):
    root,state,source=setup_sources(tmp_path,monkeypatch)
    relative=source.relative_to(root).as_posix()
    row={'text':'旧偏好','metadata':{'source_path':relative,'source_sha256':memory.digest(source.read_bytes()),'policy_version':memory.POLICY_VERSION}}
    allowed=memory.sources(root)
    assert memory.valid_result(row,'personal-main',allowed)
    source.write_text('新偏好')
    assert memory.valid_result(row,'personal-main',allowed) is None
    assert memory.valid_result({'text':'任意对话记忆'},'personal-main',allowed) is None
    source.unlink()
    assert memory.valid_result(row,'personal-main',allowed) is None


def test_outage_is_explicit_and_reflections_excluded(tmp_path,monkeypatch):
    root,state,source=setup_sources(tmp_path,monkeypatch)
    folder=root/'work/工具与效率/会话工作台/docs/memory-reflections'
    folder.mkdir(parents=True); (folder/'draft.md').write_text('模型猜测')
    assert not any('draft.md' in key[1] for key in memory.sources(root))
    async def failed(*args,**kwargs): raise TimeoutError()
    monkeypatch.setattr(memory,'request',failed)
    result=asyncio.run(memory.recall('我是谁'))
    assert result['status']=='unavailable' and not result['items']


def test_failed_ingestion_retries_without_committing_hash(tmp_path,monkeypatch):
    root,state,source=setup_sources(tmp_path,monkeypatch)
    async def failed(method,*args,**kwargs):
        if method=='POST': raise TimeoutError()
        return {}
    monkeypatch.setattr(memory,'request',failed)
    import pytest
    assert asyncio.run(memory.sync_once(root,state))['changed']==0
    assert not (state/'manifest.json').exists()


def test_credentials_filtered_and_policy_version_required(tmp_path,monkeypatch):
    root,state,source=setup_sources(tmp_path,monkeypatch)
    text='偏好中文\n密码: synthetic-test-password\n```json\n{ "api_key": "synthetic-test-key", "url": "test" }\n```\n长期目标: 旅行'
    clean=memory.sanitize(text)
    assert 'synthetic-test' not in clean and '偏好中文' in clean and '长期目标' in clean
    row={'text':'旧未过滤索引','metadata':{'source_path':source.relative_to(root).as_posix(),'source_sha256':memory.digest(source.read_bytes())}}
    assert memory.valid_result(row,'personal-main',memory.sources(root)) is None


def test_low_relevance_is_not_injected(tmp_path,monkeypatch):
    root,state,source=setup_sources(tmp_path,monkeypatch)
    row={'text':'不相关资料','metadata':{'source_path':source.relative_to(root).as_posix(),'source_sha256':memory.digest(source.read_bytes()),'policy_version':memory.POLICY_VERSION},'scores':{'reranker':0.001}}
    assert memory.valid_result(row,'personal-main',memory.sources(root)) is None
