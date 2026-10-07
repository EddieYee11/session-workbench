"""Hermes' native request hooks, recording sizes/usage only on the execution host."""
import json
import hashlib
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
    row['tool_schema_sha256']=hashlib.sha256(json.dumps(body.get('tools',[]),ensure_ascii=False,sort_keys=True).encode()).hexdigest() if body is not None else None
    row['request_payload_truncated']=bool(request.get('_truncated'))
    row['message_bytes_by_role']={role:sum(_size(m) for m in messages if m.get('role')==role) for role in ('system','developer','user','assistant','tool')}
    row['count_method']='hook-visible UTF-8 bytes (payload sanitization may truncate); token estimates from Hermes, actual tokens from provider post event'
    _save('before',row)

def after(**data):
    row={k:data.get(k) for k in ('session_id','turn_id','api_request_id','model','provider','api_call_count','api_duration','started_at','ended_at','first_chunk_at','usage','assistant_content_chars','assistant_tool_call_count','finish_reason')}
    usage=data.get('usage') or {}
    if isinstance(usage,dict):
        total=usage.get('prompt_tokens',usage.get('input_tokens'))
        details=usage.get('prompt_tokens_details') or usage.get('input_tokens_details') or {}
        cached=usage.get('cache_read_tokens',usage.get('prompt_cache_hit_tokens',details.get('cached_tokens')))
        row.update(prompt_tokens=total,cache_read_tokens=cached,
                   cache_hit_ratio=round(cached/total,4) if isinstance(total,(int,float)) and total>0 and isinstance(cached,(int,float)) else None)
    _save('after',row)

def register(ctx):
    ctx.register_hook('pre_api_request',before)
    ctx.register_hook('post_api_request',after)
    from .source_binding import bind_source
    ctx.register_hook('pre_tool_call',bind_source)
