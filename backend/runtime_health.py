"""Safe host-local protocol/model availability probes, without model turns or user writes."""
import asyncio,re
from pathlib import Path
import httpx
from claude_worker import third_party_config

async def claude(state):
    env,model=third_party_config(state)
    binary=Path('/usr/local/bin/claude')
    if not binary.is_file():raise ValueError('mini 缺少 Claude Code')
    proc=await asyncio.create_subprocess_exec(str(binary),'--version',stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL)
    try:out,_=await asyncio.wait_for(proc.communicate(),10)
    except asyncio.TimeoutError:
        proc.kill();await proc.wait();raise ValueError('Claude Code 健康探测超时') from None
    if proc.returncode:raise ValueError('Claude Code 不可用')
    credential=env.get('ANTHROPIC_AUTH_TOKEN') or env.get('ANTHROPIC_API_KEY')
    try:
        async with httpx.AsyncClient(trust_env=False,timeout=15,follow_redirects=False) as client:
            reply=await client.get(env['ANTHROPIC_BASE_URL'].rstrip('/')+'/v1/models',
                headers={'Authorization':'Bearer '+credential,'x-api-key':credential})
            reply.raise_for_status()
            available={entry.get('id') for entry in reply.json().get('data',[])}
            if model not in available:raise ValueError('第三方网关未提供 Com 指定模型；不回退其他服务')
    except (httpx.HTTPError,TypeError,AttributeError):raise ValueError('第三方网关健康探测失败，已暂停') from None
    version=re.search(r'\d+\.\d+\.\d+',out.decode(errors='replace'))
    return {'probe':'cli-version-and-third-party-model-list','version':version[0] if version else 'unknown',
            'model':model,'endpoint':env['ANTHROPIC_BASE_URL'],'model_turns':0}

async def pi(state):
    from pi_rpc import PiRPC
    rpc=PiRPC(state,'runtime-health',Path(state),tools=False)
    rpc.bind({})
    try:
        await rpc.start();result=await rpc.request({'type':'get_state'})
        if not result.get('success'):raise ValueError('Pi RPC 未就绪')
        return {'probe':'native-rpc-get-state','model':result.get('data',{}).get('model',{}).get('id'),'model_turns':0}
    finally:await rpc.stop()
