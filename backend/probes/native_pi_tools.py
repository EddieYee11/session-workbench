"""Actual native active-tool inventory, no model turn or production session."""
import argparse
import asyncio
import hashlib
import json
import os
import sys
import tempfile
import uuid
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from pi_rpc import PiRPC


OBSERVER=r'''
import {writeFileSync} from "node:fs";
import {join} from "node:path";
export default function(pi:any) {
 pi.on("session_start",()=>writeFileSync(join(process.env.COM_STATE!,"native-tool-inventory.json"),
  JSON.stringify({active:pi.getActiveTools(),all:pi.getAllTools().map((t:any)=>t.name)})));
}
'''


async def run():
    settings=Path.home()/'.pi/agent/settings.json'
    before=hashlib.sha256(settings.read_bytes()).digest() if settings.exists() else None
    with tempfile.TemporaryDirectory(prefix='com-native-tools-') as directory:
        root=Path(directory);state=root/'state';workspace=root/'workspace'
        state.mkdir(mode=0o700);workspace.mkdir()
        (state/'token').write_text(uuid.uuid4().hex);(state/'token').chmod(0o600)
        observer=root/'observe-tools.ts';observer.write_text(OBSERVER)
        async def serve(reader,writer):
            try:
                header=(await reader.readuntil(b'\r\n\r\n')).decode()
                length=next(int(line.split(':',1)[1]) for line in header.split('\r\n') if line.lower().startswith('content-length:'))
                await reader.readexactly(length)
                writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}')
                await writer.drain()
            finally:
                writer.close();await writer.wait_closed()
        server=await asyncio.start_server(serve,'127.0.0.1',0)
        port=server.sockets[0].getsockname()[1]
        rpc=PiRPC(state,'main',workspace,env={**os.environ,'COM_INTERNAL_URL':f'http://127.0.0.1:{port}'})
        safe_rpc=None
        worker_rpc=None
        command=rpc.command();rpc.argv=[*command,'--extension',str(observer)]
        try:
            await rpc.start();response=await rpc.request({'type':'get_state'})
            inventory=json.loads((state/'native-tool-inventory.json').read_text())
            active=set(inventory['active']);required={'read','bash','edit','write','grep','find','ls'}
            extensions={'bookkeeping','bookkeeping_search','task_submit'}
            assert required<=active,'A required native operation tool is inactive'
            assert extensions<=active,'Explicit builtin selection excluded business extensions'
            worker_state=root/'worker-state';worker_state.mkdir(mode=0o700)
            (worker_state/'token').write_text(uuid.uuid4().hex);(worker_state/'token').chmod(0o600)
            worker_rpc=PiRPC(worker_state,'worker-fixture',workspace,
                            env={**os.environ,'COM_INTERNAL_URL':f'http://127.0.0.1:{port}'})
            worker_rpc.argv=[*worker_rpc.command(),'--extension',str(observer)]
            await worker_rpc.start()
            worker_inventory=json.loads((worker_state/'native-tool-inventory.json').read_text())
            assert required|extensions<=set(worker_inventory['active']),'Worker loaded tools are not active'
            safe_state=root/'safe-state';safe_state.mkdir(mode=0o700)
            (safe_state/'token').write_text(uuid.uuid4().hex);(safe_state/'token').chmod(0o600)
            safe_rpc=PiRPC(safe_state,'safe-probe',workspace,tools=False,
                          env={**os.environ,'COM_INTERNAL_URL':f'http://127.0.0.1:{port}'})
            # Match the actual quality_judge custom argv: no business extension
            # is loaded. The observer registers only a lifecycle event.
            safe_command=safe_rpc.command()
            pos=safe_command.index('--extension');del safe_command[pos:pos+2]
            safe_rpc.argv=[*safe_command,'--extension',str(observer)]
            await safe_rpc.start()
            safe_inventory=json.loads((safe_state/'native-tool-inventory.json').read_text())
            assert safe_inventory['active']==[],'Judge mode enabled a native or business tool'
            after=hashlib.sha256(settings.read_bytes()).digest() if settings.exists() else None
            assert before==after,'Global Pi settings changed'
            return {'ok':True,'get_state_success':response['success'],'prompt_sent':False,
                    'temporary_state':True,'production_com_session_used':False,'global_pi_settings_unchanged':True,
                    'tool_activation':'native setActiveTools(getAllTools())','restrictive_cli_allowlist':False,
                    'main_env_operational_tools':rpc.env['COM_PI_OPERATIONAL_TOOLS'],
                    'worker_env_operational_tools':worker_rpc.env['COM_PI_OPERATIONAL_TOOLS'],
                    'judge_env_operational_tools':safe_rpc.env['COM_PI_OPERATIONAL_TOOLS'],
                    'required_native_tools_active':sorted(required),'business_extension_tools_active':sorted(extensions),
                    'worker_active_tools':worker_inventory['active'],'judge_active_tools':[],
                    'active_tools':sorted(active)}
        except AssertionError as error:
            return {'ok':False,'assertion':str(error),'active_tools':inventory['active'],
                    'all_tools':inventory['all'],'prompt_sent':False,'global_pi_settings_changed':False}
        finally:
            if safe_rpc:await safe_rpc.stop()
            if worker_rpc:await worker_rpc.stop()
            await rpc.stop();server.close();await server.wait_closed()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--output');args=parser.parse_args()
    result=asyncio.run(run())
    if args.output:
        target=Path(args.output);target.write_text(json.dumps(result,ensure_ascii=False,indent=2));target.chmod(0o600)
    print(json.dumps(result,ensure_ascii=False))
