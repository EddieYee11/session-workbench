from types import SimpleNamespace

from runtime import Runtime


def runtime(tmp_path, managed=None):
    return Runtime(SimpleNamespace(state=tmp_path, managed=lambda: managed or {}), 'token')


def test_codex_turn_usage_is_normalized(tmp_path):
    r = runtime(tmp_path)
    r.emit('codex:x', {'kind': 'status', 'status': 'completed', 'usage': {'input_tokens': 1200, 'output_tokens': 300}})
    assert r.usage('codex:x') == {'input': 1200, 'output': 300, 'total': 1500, 'context_used': None, 'context_max': None}


def test_pi_message_end_usage_is_read_from_the_jsonl(tmp_path):
    f = tmp_path / 'pi.jsonl'
    f.write_text('\n'.join([
        '{"type":"message_end","data":{"message":{"role":"assistant","usage":{"input":800,"output":200,"totalTokens":1000}}}}',
        '{"type":"message_end","data":{"message":{"role":"user"}}}',
    ]) + '\n')
    r = runtime(tmp_path, {'pi:1': {'agent': 'pi', 'pi_file': str(f)}})
    assert r.usage('pi:1')['total'] == 1000 and r.usage('pi:1')['input'] == 800


def test_usage_is_null_when_missing_or_malformed(tmp_path):
    r = runtime(tmp_path)
    assert r.usage('codex:none') is None
    r.emit('codex:bad', {'kind': 'status', 'usage': {'foo': 1}})
    assert r.usage('codex:bad') is None
    r.emit('codex:bad2', {'kind': 'status', 'usage': 'not-a-dict'})
    assert r.usage('codex:bad2') is None
