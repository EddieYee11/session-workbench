"""Hermes' native request hooks, recording sizes/usage only on the execution host."""
import json
import os
import threading
from pathlib import Path

_LOCK=threading.Lock()

def _size(value):
    if value is None:return 0
    return len(json.dumps(value,ensure_ascii=False,separators=(',',':')).encode())

def _save(stage,data):
    home=Path(os.environ.get('HERMES_HOME',str(Path.home()/'.hermes')))
    if home.name!='com-personal':return
    row={'stage':stage,**data}
    path=home/'logs/com-context-metrics.jsonl'
    with _LOCK:
        if path.exists() and path.stat().st_size>8_000_000:
            path.replace(path.with_suffix('.previous.jsonl'))
        fd=os.open(path,os.O_APPEND|os.O_CREAT|os.O_WRONLY,0o600)
        with os.fdopen(fd,'a') as f:f.write(json.dumps(row,ensure_ascii=False)+'\n')

def before(**data):
    request=data.get('request') or {}
    if not isinstance(request,dict):request={}
    body=request.get('body') if isinstance(request.get('body'),dict) else None
    messages=data.get('request_messages') or []
    row={k:data.get(k) for k in ('session_id','turn_id','api_request_id','model','provider','api_call_count','retry_count','started_at','approx_input_tokens','tool_count')}
    row['system_bytes']=_size(data.get('system_prompt'))
    row['tool_schema_bytes']=_size(body.get('tools',[])) if body is not None else None
    row['request_payload_truncated']=bool(request.get('_truncated'))
    row['message_bytes_by_role']={role:sum(_size(m) for m in messages if m.get('role')==role) for role in ('user','assistant','tool')}
    row['count_method']='hook-visible UTF-8 bytes (payload sanitization may truncate); token estimates from Hermes, actual tokens from provider post event'
    _save('before',row)

def after(**data):
    _save('after',{k:data.get(k) for k in ('session_id','turn_id','api_request_id','model','provider','api_call_count','api_duration','started_at','ended_at','first_chunk_at','usage','assistant_content_chars','assistant_tool_call_count','finish_reason')})

def register(ctx):
    ctx.register_hook('pre_api_request',before)
    ctx.register_hook('post_api_request',after)
