import { appendFileSync } from 'node:fs';
export default function(pi: any) {
  const path=process.env.SESSION_WORKBENCH_EVENTS;
  let last=0;
  let pending: any = null;
  const dispatched = new Set<string>();
  function body(message: any) {
    return typeof message?.content === 'string' ? message.content :
      (message?.content || []).filter((x: any) => x.type === 'text').map((x: any) => x.text).join('\n');
  }
  function write(type: string, data: any, ctx: any) {
    if (!path) return;
    try { appendFileSync(path, JSON.stringify({type,time:Date.now()/1000,sid:ctx.sessionManager.getSessionId(),file:ctx.sessionManager.getSessionFile(),data})+'\n',{mode:0o600}); } catch {}
  }
  pi.on('session_start', (_e: any, ctx: any) => {
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === 'message' && entry.message?.role === 'user' && entry.message?.com_request_id)
        dispatched.add(entry.message.com_request_id);
    }
    write('com_input_capabilities', {stable_message_identity_v1:true}, ctx);
  });
  // The command owns this brief input preflight. Interactive input cannot be
  // mistaken for its user echo, even when the wording happens to be identical.
  pi.on('input', (event: any) => {
    if (!pending) return {action:'continue'};
    if (!pending.inputSeen && event.source === 'extension' && event.text === pending.text) {
      pending.inputSeen = true;
      return {action:'continue'};
    }
    return {action:'handled'};
  });
  pi.on('message_start', (event: any, ctx: any) => {
    if (pending?.inputSeen && event.message?.role === 'user' && body(event.message) === pending.text) {
      pending.message = event.message;
      event.message.com_request_id = pending.requestId;
    }
    write('message_start', event, ctx);
  });
  pi.on('message_end', (event: any, ctx: any) => {
    if (pending?.message === event.message && event.message?.role === 'user') {
      const requestId = pending.requestId;
      const message = {...event.message, com_request_id:requestId};
      write('message_end', {...event, message}, ctx);
      const resolve = pending.resolve;
      pending = null;
      // Confirm after Pi's message_end persistence, rather than treating the
      // extension command or an in-memory message_start as durable acceptance.
      setTimeout(() => {
        const entry = ctx.sessionManager.getBranch().find((x: any) =>
          x.type === 'message' && x.message?.role === 'user' && x.message?.com_request_id === requestId);
        write('com_input_result', entry ?
          {requestId, ok:true, messageId:'pi:com:'+requestId, nativeEntryId:entry.id} :
          {requestId, ok:false, error:'Pi 未确认原生消息持久记录，请核实状态；不要重复提交'}, ctx);
        resolve();
      }, 0);
      // Pi persists this real user message after message_end handlers return.
      return {message};
    }
    write('message_end', event, ctx);
  });
  pi.registerCommand('com-input', {
    description:'Submit a Com! user message with its durable request identity',
    handler: async (arg: string, ctx: any) => {
      let requestId = '';
      let timer: any;
      try {
        if (!/^[A-Za-z0-9_-]{20,1500000}$/.test(arg)) throw new Error('无效的消息请求');
        const data = JSON.parse(Buffer.from(arg, 'base64url').toString('utf8'));
        requestId = data.requestId;
        if (typeof requestId !== 'string' || !/^[A-Za-z0-9_-]{10,100}$/.test(requestId)) throw new Error('无效的请求标识');
        if (typeof data.text !== 'string' || !data.text.trim()) throw new Error('输入为空');
        if (dispatched.has(requestId)) throw new Error('消息已交办，请核实原发送状态；不会再次执行');
        if (pending || !ctx.isIdle() || ctx.hasPendingMessages()) throw new Error('Pi 正在处理消息，请完成后再发送');
        dispatched.add(requestId);
        await new Promise<void>((resolve, reject) => {
          pending = {requestId, text:data.text, inputSeen:false, message:null, resolve};
          timer = setTimeout(() => reject(new Error('Pi 未确认实际消息，请核实状态；不要重复提交')), 7000);
          pi.sendUserMessage(data.text, {expandPromptTemplates:false});
        });
      } catch (error: any) {
        if (requestId) write('com_input_result', {requestId, ok:false, error:String(error?.message || error)}, ctx);
      } finally {
        clearTimeout(timer);
        if (pending?.requestId === requestId) pending = null;
      }
    },
  });
  for(const type of ['session_start','agent_start','agent_end','agent_settled','queue_update','tool_execution_start','tool_execution_update','tool_execution_end'])
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
