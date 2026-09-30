import { appendFileSync } from 'node:fs';
export default function(pi: any) {
  const path=process.env.SESSION_WORKBENCH_EVENTS;
  let last=0;
  function write(type: string, data: any, ctx: any) {
    if (!path) return;
    try { appendFileSync(path, JSON.stringify({type,time:Date.now()/1000,sid:ctx.sessionManager.getSessionId(),file:ctx.sessionManager.getSessionFile(),data})+'\n',{mode:0o600}); } catch {}
  }
  for(const type of ['session_start','agent_start','agent_end','message_start','message_end','tool_execution_start','tool_execution_update','tool_execution_end'])
    pi.on(type, (e:any,c:any)=>write(type,e,c));
  pi.on('message_update',(e:any,c:any)=>{ if(Date.now()-last>100){last=Date.now();write('message_update',e,c);} });
}
