"""Native prompt failures retain a useful cause without raw credentials."""
import asyncio
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pi_rpc import PiRPC, rejection_labels


@pytest.mark.parametrize('name',['main','worker-fixture'])
def test_operational_native_tools_override_narrow_global_defaults_without_losing_extensions(tmp_path,monkeypatch,name):
    fake_home=tmp_path/'home';settings=fake_home/'.pi/agent/settings.json'
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({'defaultTools':['read','bash','edit'],
                                    'extensions':['/native/bookkeeping.ts','/native/lane-tools.ts']}))
    monkeypatch.setattr(Path,'home',classmethod(lambda cls:fake_home))
    before=settings.read_bytes()
    rpc=PiRPC(tmp_path/'state',name,tmp_path,tools=True,env={'COM_PI_OPERATIONAL_TOOLS':'0'})
    command=rpc.command()
    assert rpc.env['COM_PI_OPERATIONAL_TOOLS']=='1'
    assert '--tools' not in command and '--no-builtin-tools' not in command
    assert str(Path(__file__).resolve().parents[1]/'com-pi.ts') in command
    assert '/native/bookkeeping.ts' in command and '/native/lane-tools.ts' not in command
    assert settings.read_bytes()==before


def test_judge_no_builtin_tools_and_custom_probe_command_are_preserved(tmp_path):
    rpc=PiRPC(tmp_path/'state','judge-fixture',tmp_path,tools=False,env={'COM_PI_OPERATIONAL_TOOLS':'1'})
    judge=rpc.command()
    assert rpc.env['COM_PI_OPERATIONAL_TOOLS']=='0'
    assert '--no-builtin-tools' in judge and '--no-skills' in judge and '--tools' not in judge
    custom=['/fixture/pi','--no-builtin-tools']
    assert PiRPC(tmp_path/'probe','safe-probe',tmp_path,argv=custom).command()==custom


def test_native_rejection_exposes_only_fixed_labels():
    result = rejection_labels("EPERM: operation not permitted, mkdir '/home/user/.pi/agent/auth.json.lock' Authorization: secret-token")
    assert result == ['auth_file', 'auth_lock', 'mkdir', 'permission_denied']
    assert 'secret-token' not in str(result) and '/home/user' not in str(result)


def test_auth_preflight_failure_classified_without_provider_or_key():
    assert rejection_labels('No API key found for private-provider. secret-value') == ['missing_api_key']
    assert rejection_labels('opaque-secret-value') == ['unclassified']


def rejected_prompt(tmp_path, started):
    script = tmp_path / 'native.py'
    script.write_text('''import json,sys
for line in sys.stdin:
 command=json.loads(line)
 if command['type']=='prompt':
  if STARTED:
   print(json.dumps({'type':'message_start','message':{'role':'user','content':command['message']}}),flush=True)
  print(json.dumps({'type':'response','id':command['id'],'command':'prompt','success':False,'error':"EPERM mkdir '/home/user/.pi/agent/auth.json.lock' secret-token"}),flush=True)
 else:print(json.dumps({'type':'response','id':command['id'],'command':command['type'],'success':True,'data':{}}),flush=True)
'''.replace('STARTED', str(started)))
    async def scenario():
        rpc = PiRPC(tmp_path, 'rejection', tmp_path, argv=[sys.executable, '-u', str(script)])
        try:
            events = [event async for event in rpc.stream('fixture input', 'request-fixture', context={})]
            error = next(payload for name, payload in events if name == 'error')
            assert error['native_rejection'] and error['reason_code'] == 'auth_lock_denied'
            assert error['native_started'] == started
            assert error['uncertain'] == started
            assert error['delivery'] == ('unknown' if started else 'not_sent')
            assert not any(name == 'input.accepted' for name, _ in events)
            saved = rpc.events.read_text()
            assert 'rpc.rejected' in saved and 'auth_lock' in saved
            assert 'secret-token' not in saved and '/home/user' not in saved
        finally:
            await rpc.stop()
    asyncio.run(scenario())


def test_authoritative_preflight_reject_without_native_start_is_not_sent(tmp_path):
    rejected_prompt(tmp_path, False)


def test_reject_after_native_user_echo_always_remains_unknown(tmp_path):
    rejected_prompt(tmp_path, True)


@pytest.mark.skipif(sys.platform != 'darwin', reason='Native macOS file boundary')
def test_auth_lock_lifecycle_allowed_but_auth_and_readonly_project_writes_denied():
    from execution_boundary import sandbox
    # Keep this fixture outside the globally allowed OS temporary directory.
    # Its fake auth file contains no credentials and cannot affect native auth.
    with tempfile.TemporaryDirectory(prefix='.sandbox-proof-', dir=Path(__file__).resolve().parents[2]) as directory:
        root = Path(directory)
        home, state, project = root / 'home', root / 'state', root / 'project'
        auth_dir = home / '.pi/agent'
        auth_dir.mkdir(parents=True)
        state.mkdir()
        project.mkdir()
        auth = auth_dir / 'auth.json'
        auth.write_text('fixture-auth')
        settings = auth_dir / 'settings.json'
        settings.write_text('fixture-settings')
        script = '''import os,sys,json
from pathlib import Path
auth,settings,project=map(Path,json.loads(sys.argv[1]))
lock=Path(str(auth)+'.lock')
lock.mkdir();os.utime(lock,None);lock.rmdir()
for path in [auth,settings,project/'must-not-write']:
 try:path.write_text('unexpected')
 except PermissionError:pass
 else:raise SystemExit(2)
print('boundary-verified')
'''
        with patch('execution_boundary.Path.home', return_value=home):
            command = sandbox([sys.executable, '-B', '-c', script,
                               json.dumps([str(auth), str(settings), str(project)])], state, project, readonly=True)
        result = subprocess.run(command, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr[-1000:]
        assert result.stdout.strip() == 'boundary-verified'
        assert auth.read_text() == 'fixture-auth' and settings.read_text() == 'fixture-settings'
        assert not (project / 'must-not-write').exists()
