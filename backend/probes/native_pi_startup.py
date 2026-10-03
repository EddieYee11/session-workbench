"""Get-state-only startup comparison; never retain native raw stderr."""
import argparse
import asyncio
import json
import os
import re
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pi_rpc import PiRPC


class DiagnosticRPC(PiRPC):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.stderr_classifications = set()
        self.stderr_lines = 0
        self.exit_code = None
        self.io_labels = set()

    async def drain_stderr(self, proc):
        while raw := await proc.stderr.readline():
            self.stderr_lines += 1
            # Only fixed labels reach the report. No path/token/request headers.
            line = raw.decode(errors='replace').lower()
            labels = {'permission_denied': r'eperm|eacces|operation not permitted|permission denied',
                      'jiti_cache': r'jiti|jiti-cache', 'node_cache': r'node.*cache|compile.cache',
                      'global_pi_config': r'\.pi[/\\]agent|\.pi[/\\]bin',
                      'auth_file': r'auth\.json', 'settings_file': r'settings\.json',
                      'models_file': r'models\.json', 'sandbox': r'sandbox',
                      'missing_dependency': r'cannot find module|module not found|enoent',
                      'file_write': r'writefile|mkdir|open.*["\x27]w|unlink|rename',
                      'network_failure': r'fetch failed|econnrefused|econnreset'}
            self.stderr_classifications.update(name for name, pattern in labels.items() if re.search(pattern, line))
            for operation in ('mkdir', 'open', 'rename', 'write', 'unlink', 'rmdir', 'stat', 'symlink'):
                if re.search(r'\b' + operation + r'\b', line):
                    self.io_labels.add('syscall:' + operation)
            for target in re.findall(r"['\"]([^'\"]+)['\"]", line):
                if '/' not in target or any(char in target for char in ('\n', '\r', '?')):
                    continue
                basename = Path(target).name
                if basename in {'.pi', 'agent', 'bin', 'auth.json', 'auth.json.lock', 'models.json',
                                'settings.json', 'extensions', 'sessions', 'jiti', 'jiti-cache', 'npm', 'git', 'tools', 'prompts'}:
                    self.io_labels.add('target_basename:' + basename)
                if target.startswith(self.cwd.lower() + '/'):
                    self.io_labels.add('target_scope:workspace')
                elif target.startswith(str(Path.home() / '.pi').lower() + '/'):
                    self.io_labels.add('target_scope:global_pi')
                elif target.startswith('.pi/'):
                    self.io_labels.add('target_scope:relative_pi')
                for segment in ('.pi', 'agent', 'bin', 'sessions', 'cache', 'extensions', 'node_modules', 'locks', 'npm', 'git', 'tools', 'prompts'):
                    if segment in Path(target).parts:
                        self.io_labels.add('target_segment:' + segment)
        self.exit_code = proc.returncode


async def run(workspace_path=None):
    results = []
    with tempfile.TemporaryDirectory(prefix='com-pi-startup-') as directory:
        root = Path(directory)
        workspace = Path(workspace_path).resolve() if workspace_path else root / 'workspace'
        if not workspace_path:
            workspace.mkdir()
        for label, isolated, tools in [('normal_full', False, True), ('readonly_full', True, True),
                                       ('normal_minimal', False, False), ('readonly_minimal', True, False)]:
            state = root / label
            state.mkdir(mode=0o700)
            (state / 'token').write_text(uuid.uuid4().hex)
            rpc = DiagnosticRPC(state, 'startup', workspace, tools=tools, isolated=isolated,
                                readonly=True, env={**os.environ, 'COM_INTERNAL_URL': 'http://127.0.0.1:1'})
            rpc.bind({})
            started = time.monotonic()
            outcome = {'case': label, 'isolated': isolated, 'readonly': True, 'native_tools': tools}
            try:
                await rpc.start()
                reply = await rpc.request({'type': 'get_state'})
                outcome.update(ok=reply.get('success', True), native_session_created=bool(rpc.session))
            except Exception as exc:
                outcome.update(ok=False, error_class=type(exc).__name__)
            finally:
                outcome['startup_ms'] = round((time.monotonic() - started) * 1000)
                await rpc.stop()
                outcome['exit_code'] = rpc.exit_code
                outcome['stderr_lines'] = rpc.stderr_lines
                outcome['safe_error_labels'] = sorted(rpc.stderr_classifications)
                outcome['safe_io_labels'] = sorted(rpc.io_labels)
                results.append(outcome)
    return {'prompt_sent': False, 'temporary_state': True, 'raw_stderr_retained': False,
            'existing_workspace': bool(workspace_path), 'cases': results}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output')
    parser.add_argument('--workspace')
    args = parser.parse_args()
    result = asyncio.run(run(args.workspace))
    if args.output:
        target = Path(args.output)
        target.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        target.chmod(0o600)
    print(json.dumps(result, ensure_ascii=False))
