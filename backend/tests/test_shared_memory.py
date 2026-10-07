"""Shared knowledge remains one sourced Markdown authority while mobile can browse it."""
import sys
from pathlib import Path
import pytest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from memory_catalog import MemoryCatalog, SharedKnowledgeCatalog
from memory import digest


def knowledge(root, name, text):
    path = root / '_global/记忆库/知识' / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def test_all_nested_knowledge_visible_without_creating_catalog_copies(tmp_path):
    a = knowledge(tmp_path, '协作偏好_Agent工作方式.md', '# 协作偏好\n\n直接执行并验证结果。')
    knowledge(tmp_path, 'work/搜狐_运营.md', '# 搜狐运营\n\n保留素材来源。')
    private = knowledge(tmp_path, '临时.md', 'password: must-never-reach-mobile')
    outside = tmp_path / 'outside.md'
    outside.write_text('# 不在白名单\n\n排除')
    (a.parent / 'linked.md').symlink_to(outside)
    knowledge(tmp_path, 'old.sync-conflict-one.md', '# 同步冲突\n\n排除')
    knowledge(tmp_path, '_archive/old.md', '# 归档\n\n排除')
    rows = SharedKnowledgeCatalog(tmp_path).list()
    assert len(rows) == 2
    assert {r['category'] for r in rows} == {'关于我', '工作'}
    assert all(r['read_only'] and r['kind'] == 'knowledge' for r in rows)
    row = next(r for r in rows if r['title'] == '协作偏好')
    assert row['source']['sha256'] == digest(a.read_bytes())
    assert row['content'] == a.read_text()
    assert private.read_text() == 'password: must-never-reach-mobile'
    assert not (tmp_path / '_global/记忆库/Com').exists()


def test_source_edits_and_deletions_appear_under_the_same_identity(tmp_path):
    p = knowledge(tmp_path, '财务.md', '# 财务\n\n旧口径')
    catalog = SharedKnowledgeCatalog(tmp_path)
    before = catalog.list()[0]
    p.write_text('# 财务\n\n新的已确认口径')
    after = catalog.get(before['id'])
    assert before['id'] == after['id'] and before['source']['sha256'] != after['source']['sha256']
    assert '旧口径' not in after['content'] and '新' in after['content']
    p.unlink()
    assert catalog.list() == []
    with pytest.raises(ValueError, match='not found'):
        catalog.get(before['id'])
    with pytest.raises(ValueError, match='Invalid'):
        catalog.get('../../outside')


def test_projection_filters_sensitive_content_and_has_no_effect_on_agent_context(tmp_path):
    knowledge(tmp_path, '生活.md', '# 生活\n\n保留原文。\napi_key: hidden\n\n```json\n{"password":"hidden"}\n```\n\n末尾仍在。')
    catalog = MemoryCatalog(tmp_path)
    saved = catalog.save('明确的个人偏好', '关于我', {'message_id':'test-human', 'quote':'明确的个人偏好'})
    row = SharedKnowledgeCatalog(tmp_path).list()[0]
    assert 'hidden' not in row['content'] and '末尾仍在' in row['content']
    assert catalog.context()[0]['id'] == saved['id'] and len(catalog.context()) == 1
