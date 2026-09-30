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
  // The Android composer sends only an opaque, base64url-encoded configuration
  // request here. The extension confirms the effective settings before the
  // backend is allowed to paste the user's separate message into the TUI.
  pi.registerCommand('com-set-model', {
    description: 'Set the model and thinking level for this managed Com! session',
    handler: async (arg: string, ctx: any) => {
      let requestId = '';
      let previousModel: any;
      let previousEffort = '';
      let changedModel = false;
      try {
        if (!/^[A-Za-z0-9_-]{20,2000}$/.test(arg)) throw new Error('无效的配置请求');
        const data = JSON.parse(Buffer.from(arg, 'base64url').toString('utf8'));
        requestId = data.requestId;
        if (typeof requestId !== 'string' || !/^[0-9a-f-]{36}$/.test(requestId)) throw new Error('无效的请求标识');
        if (!ctx.isIdle() || ctx.hasPendingMessages()) throw new Error('Pi 正在处理消息，请稍后切换');
        const modelId = data.model || '';
        const effort = data.effort || '';
        if (typeof modelId !== 'string' || typeof effort !== 'string') throw new Error('无效的模型设置');
        if (effort && !['off','minimal','low','medium','high','xhigh','max'].includes(effort)) throw new Error('不支持的推理强度');
        previousModel = ctx.model;
        previousEffort = pi.getThinkingLevel();
        if (modelId) {
          if (!previousModel) throw new Error('Pi 尚未加载当前模型');
          const slash = modelId.indexOf('/');
          if (slash < 1 || slash === modelId.length - 1) throw new Error('无效的模型名称');
          const model = ctx.modelRegistry.find(modelId.slice(0, slash), modelId.slice(slash + 1));
          if (!model) throw new Error('模型未在 Pi 中配置');
          if (!await pi.setModel(model)) throw new Error('这个模型尚未在 Mac mini 配置认证');
          changedModel = true;
        }
        if (effort) pi.setThinkingLevel(effort);
        const actualEffort = pi.getThinkingLevel();
        if (effort && actualEffort !== effort) throw new Error('当前模型不支持这个推理强度');
        write('config_result', {requestId, ok:true, model:modelId || `${ctx.model?.provider || ''}/${ctx.model?.id || ''}`, effort:actualEffort}, ctx);
      } catch (error: any) {
        if (changedModel && previousModel) {
          try { await pi.setModel(previousModel); pi.setThinkingLevel(previousEffort); } catch {}
        } else if (previousEffort) {
          try { pi.setThinkingLevel(previousEffort); } catch {}
        }
        if (requestId) write('config_result', {requestId, ok:false, error:String(error?.message || error)}, ctx);
      }
    },
  });
}
