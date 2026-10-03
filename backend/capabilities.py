"""Pi 能力清单：从本机 Pi 配置导出，注入主对话，让 Hermes 知道系统能做什么。

后端与 Pi 同机（都跑在 mini），所以直接读本地文件，不经 ssh 或 HTTP。
清单只作路由提示，不参与授权裁决——裁决见 task_tools.py。
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import yaml

PI_SETTINGS = Path.home() / ".pi" / "agent" / "settings.json"

# 不进清单：前四个是基础设施，由 Pi 自己按需触发；bitwarden-vault 是取凭据的中间步骤，
# 不是 Eddie 会用一句话交办的活（Pi 需要时自己会用，隐藏它不削减 Pi 的能力）
HIDE = {"bash-guard", "cost-ledger", "model-fallback", "lane-tools", "bitwarden-vault"}

# 自动提取拿不到描述时的兜底（键为能力 id）
NOTE: dict[str, str] = {}

_FRONTMATTER = re.compile(r"\A---\s*\n(.*?)\n---", re.S)
_REGISTER = re.compile(r"registerTool\(\{")
_FIELD = {
    "name": re.compile(r'\bname:\s*"([^"]{1,80})"'),
    "label": re.compile(r'\blabel:\s*"([^"]{1,80})"'),
    "snippet": re.compile(r'\bpromptSnippet:\s*"([^"]{1,600})"'),
}


def _settings() -> dict:
    try:
        data = json.loads(PI_SETTINGS.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _trim(text: str, limit: int = 240) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def _from_skill(path: Path) -> dict | None:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    match = _FRONTMATTER.match(text)
    if not match:
        return None
    try:
        fields = yaml.safe_load(match.group(1))
    except yaml.YAMLError:
        return None
    if not isinstance(fields, dict):
        return None
    name = str(fields.get("name") or path.parent.name)
    desc = str(fields.get("description") or NOTE.get(name, ""))
    return {"id": name, "kind": "skill", "label": name, "text": _trim(desc)}


def _from_extension(path: Path) -> list[dict]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    found = []
    for chunk in _REGISTER.split(text)[1:]:
        name = _FIELD["name"].search(chunk)
        if not name:
            continue
        label = _FIELD["label"].search(chunk)
        snippet = _FIELD["snippet"].search(chunk)
        tool = name.group(1)
        found.append({
            "id": tool,
            "kind": "extension",
            "label": label.group(1) if label else tool,
            "text": _trim((snippet.group(1) if snippet else "") or NOTE.get(tool, "")),
        })
    return found


def _paths() -> tuple[list[Path], list[Path]]:
    config = _settings()
    skills = [Path(p) for p in config.get("skills", []) if isinstance(p, str)]
    extensions = [Path(p) for p in config.get("extensions", []) if isinstance(p, str)]
    skill_files = sorted(p for d in skills for p in d.glob("*/SKILL.md"))
    return extensions, skill_files


def _stamp(paths: list[Path]) -> tuple:
    out = []
    for path in paths:
        try:
            out.append((str(path), path.stat().st_mtime_ns))
        except OSError:
            out.append((str(path), None))
    return (str(PI_SETTINGS), *out)


_CACHE: dict = {"key": None, "items": []}


def manifest() -> list[dict]:
    """Pi 当前装了什么能力。settings.json 列出的 extension 才读，不 glob 目录（有 .bak 干扰）。"""
    extensions, skill_files = _paths()
    key = _stamp([PI_SETTINGS] + extensions + skill_files)
    if _CACHE["key"] == key:
        return _CACHE["items"]

    items: list[dict] = []
    for path in extensions:
        if path.stem in HIDE:
            continue
        items.extend(_from_extension(path))
    for path in skill_files:
        entry = _from_skill(path)
        if entry and entry["text"] and entry["id"] not in HIDE:
            items.append(entry)

    _CACHE.update(key=key, items=items)
    return items


def render() -> str:
    """供注入主对话的紧凑文本块；拿不到清单返回空串。"""
    items = manifest()
    if not items:
        return ""
    lines = [
        "本机发现的能力（文件扫描不能证明已加载或可用，调用前查询 capability_search）：",
        "· Pi 主线可直接执行原生工具及项目工作；独立 Pi / Claude / Codex 按实际需要选择，由运行时健康探测确认可用",
    ]
    for item in items:
        head = f"· Pi · {item['label']}"
        if item["label"] != item["id"]:
            head += f"（{item['id']}）"
        lines.append(f"{head}：{item['text']}")
    return "\n".join(lines)


class CapabilityRegistry:
    """Host-scoped observations, separate discovery/loading from real verification."""
    def __init__(self, state, host=None, clock=None):
        import socket, time
        self.path = Path(state) / 'capabilities.sqlite'
        self.config_path = Path(state)/'agent-config.json'
        self.host = host or socket.gethostname()
        self.clock = clock or time.time
        self.runtime_versions = {}
        import sqlite3
        with sqlite3.connect(self.path) as db:
            db.execute('CREATE TABLE IF NOT EXISTS capabilities(key TEXT PRIMARY KEY,data TEXT NOT NULL)')
        self.path.chmod(0o600)

    def version(self, runtime='pi'):
        import hashlib
        paths = [PI_SETTINGS, *_paths()[0], *_paths()[1]] if runtime == 'pi' else [Path.home()/'.claude/settings.json']
        paths += [self.config_path,Path(__file__).with_name('requirements.txt')]
        paths += [Path(__file__).with_name(name) for name in ('com-pi.ts','pi_rpc.py','pi_main.py','claude_worker.py','worker_runtime.py',
                  'runtime.py','app.py','policy.py','agent_tools.py','workspace_copies.py','execution_boundary.py')]
        runtime_bin=Path('/usr/local/bin/'+('claude' if runtime=='claude' else 'pi' if runtime=='pi' else 'codex'))
        digest = hashlib.sha256()
        try:
            info=runtime_bin.resolve().stat();digest.update(str((info.st_mtime_ns,info.st_size)).encode())
        except OSError:
            digest.update(b'runtime-missing')
        digest.update(self.runtime_versions.get(runtime, '').encode())
        for path in paths:
            digest.update(str(path).encode())
            try:
                digest.update(path.read_bytes())
            except OSError:
                digest.update(b'missing')
        return digest.hexdigest()

    def observe(self, ident, runtime='pi', project='', state='loaded', evidence=None, fixture=False):
        import hashlib, sqlite3
        if state not in ('discovered', 'loaded', 'verified', 'unavailable'):
            raise ValueError('Invalid capability observation')
        if state == 'verified' and (fixture or not evidence):
            raise ValueError('Verification requires non-fixture evidence')
        version = self.version(runtime)
        key = hashlib.sha256(json.dumps([self.host,runtime,project,ident]).encode()).hexdigest()
        with sqlite3.connect(self.path) as db:
            old = db.execute('SELECT data FROM capabilities WHERE key=?', (key,)).fetchone()
            item = json.loads(old[0]) if old else {}
            if item.get('config_version') != version:
                item = {}
            # A loaded report does not erase a still-valid real-success observation.
            if state == 'loaded' and item.get('state') == 'verified' and item.get('verified_at',0)+86400 > self.clock():
                state = 'verified'
            item.update(id=ident,host=self.host,runtime=runtime,project=project,config_version=version,
                        state=state,observed_at=self.clock())
            if state == 'verified' and evidence:
                item.update(verified_at=self.clock(),evidence=evidence)
            if state == 'unavailable':
                item.pop('verified_at',None)
                item['evidence'] = evidence
            db.execute('INSERT OR REPLACE INTO capabilities VALUES (?,?)', (key,json.dumps(item)))
        return item

    def search(self, query='', runtime=None, project=''):
        import sqlite3
        with sqlite3.connect(self.path) as db:
            items = [json.loads(row[0]) for row in db.execute('SELECT data FROM capabilities')]
        for executor in ('pi','claude','codex'):
            if not any(i['id']=='runtime:'+executor and i['runtime']==executor and i['host']==self.host for i in items):
                items.append(self.observe('runtime:'+executor,runtime=executor,state='discovered'))
        discovered=manifest()
        for found in discovered:
            if not any(i['id']==found['id'] and i['runtime']=='pi' and i['project']==project for i in items):
                items.append(self.observe(found['id'],project=project,state='discovered'))
        descriptions = {i['id']:i for i in discovered}
        versions={name:self.version(name) for name in {i['runtime'] for i in items}}
        result = []
        for item in items:
            if item['host'] != self.host or (runtime and item['runtime']!=runtime) or item['project']!=project:
                continue
            item = {**descriptions.get(item['id'],{}), **item}
            if item['config_version'] != versions[item['runtime']]:
                item.update(state='discovered', invalidation='configuration_or_dependency_changed')
            elif item['state']=='verified' and item.get('verified_at',0)+86400 <= self.clock():
                item.update(state='loaded', invalidation='verification_expired')
            if not query or query.lower() in json.dumps(item,ensure_ascii=False).lower():
                result.append(item)
        return result
