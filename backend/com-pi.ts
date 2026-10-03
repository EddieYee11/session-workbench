/** Com transport only: never uses a WeChat lane, gateway session or model-visible token. */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readFileSync } from "node:fs";
import { join } from "node:path";

function context(): any { return JSON.parse(readFileSync(process.env.COM_PI_CONTEXT!, "utf8")); }
async function call(name: string, args: any, ctx?: any): Promise<any> {
 const token = readFileSync(join(process.env.COM_STATE!, "token"), "utf8").trim();
 const response = await fetch((process.env.COM_INTERNAL_URL || "http://127.0.0.1:8650") + "/internal/agent/" + name, {
  method:"POST", headers:{Authorization:"Bearer "+token,"Content-Type":"application/json"},
  body:JSON.stringify({context:ctx || context(),args}), signal:AbortSignal.timeout(30000),
 });
 const result:any = await response.json();
 if (!response.ok) throw new Error(result.detail || "Com tool rejected");
 return result;
}
const schemas:Record<string,any> = {
 archive_path:Type.Object({relative_path:Type.String(),request_id:Type.String()}),
 capability_search:Type.Object({query:Type.Optional(Type.String()),runtime:Type.Optional(Type.String())}),
 task_submit:Type.Object({request_id:Type.String(),title:Type.String(),prompt:Type.String(),agent:Type.Union([Type.Literal("pi"),Type.Literal("claude"),Type.Literal("codex")]),relative_cwd:Type.String(),sandbox:Type.String(),source_quote:Type.String(),completion_condition:Type.String(),goal_id:Type.Optional(Type.String())}),
 task_verify:Type.Object({task_id:Type.String(),checks:Type.Array(Type.Object({type:Type.String(),path:Type.Optional(Type.String()),value:Type.Optional(Type.String()),command:Type.Optional(Type.String())}))}),
 task_merge:Type.Object({task_id:Type.String()}),
 task_status:Type.Object({task_id:Type.Optional(Type.String())}),
 task_send:Type.Object({task_id:Type.String(),text:Type.String(),request_id:Type.String(),constraint_type:Type.Optional(Type.String())}),
 task_cancel:Type.Object({task_id:Type.String(),request_id:Type.String()}),
 goal_upsert:Type.Object({request_id:Type.String(),goal_id:Type.Optional(Type.String()),title:Type.String(),completion_condition:Type.String(),next_step:Type.String(),source_quote:Type.String(),due_at:Type.Optional(Type.Number())}),
 goal_update:Type.Object({goal_id:Type.String(),status:Type.String(),next_step:Type.Optional(Type.String()),evidence:Type.Optional(Type.Array(Type.Object({reference:Type.String()})))}),
 goal_status:Type.Object({goal_id:Type.Optional(Type.String())}),
 react_to_user_message:Type.Object({message_id:Type.String(),reaction_token:Type.String(),emoji:Type.String()}),
 propose_work:Type.Object({request_id:Type.String(),title:Type.String(),prompt:Type.String(),relative_cwd:Type.String(),agent:Type.String(),sandbox:Type.String(),actual_action:Type.Object({tool:Type.String(),args:Type.Record(Type.String(),Type.Unknown())})}),
};
const descriptions:Record<string,string> = {
 archive_path:"可恢复地归档用户明确指定的工作区对象，保存原路径和恢复凭据，不覆盖、不永久删除。",
 capability_search:"查询当前主机能力及发现/加载/真实验证状态。未验证不能说已可用。",
 task_submit:"仅在独立并行、耗时或专门能力有益时委派；Pi 主线可直接工作，不强制派活。可选独立 Pi、Claude、Codex。source_quote 引用真实用户消息，选项续答沿已关联原交办。已受理不代表已执行。",
 task_verify:"通过真实文件/测试检查验收结束的原任务。checks type=file_exists/file_contains/tests，tests 使用项目测试命令，不根据文本完成通过。",
 task_merge:"机器验收通过后按项目串行合入独立副本。基线/Syncthing 未通过时保留补丁暂停。",
 task_status:"查询现有任务真实执行、输入送达、产物和验收状态。",
 task_send:"复用原任务补充约束或已授权要求；constraint_type 支持 read_only/preserve_style/forbid_path/note。",
 task_cancel:"停止用户指定的原任务，实际终止后才显示已停止。",
 goal_upsert:"记录用户明确交办的长期目标和可执行下一步，沿原授权推进。愿望只能讨论。",
 goal_status:"查看目标状态和原授权。",
 goal_update:"更新同一原授权下目标的下一步。任务已结束未验收时设 waiting_acceptance 并清空下一步，不能重复派发。目标完成需真实验收与证据。",
 propose_work:"提交具体不可逆删除动作供用户批准；不能把愿望变为授权。",
 react_to_user_message:"按本轮 reaction 参数为用户消息附表情。",
};
export default function (pi:ExtensionAPI) {
 for (const [name, parameters] of Object.entries(schemas)) {
  pi.registerTool({name,label:name,description:descriptions[name],parameters,
   async execute(_id,args){const result = await call(name,args);return {content:[{type:"text",text:JSON.stringify(result)}],details:result};},
  });
 }
 pi.on("session_start",async (_event,ctx)=>{
  await call("loaded",{tools:pi.getAllTools().map(t=>t.name)},{}).catch(()=>{});
 });
 pi.on("tool_call",async(event)=>{
  if (event.toolName in schemas) return;
  try { await call("authorize_tool",{tool:event.toolName,args:event.input,tool_call_id:event.toolCallId}); }
  catch(e:any) { return {block:true,reason:e.message}; }
 });
 pi.on("tool_result",async(event)=>{
  if (event.toolName in schemas) return;
  await call("tool_result",{tool:event.toolName,args:event.input,tool_call_id:event.toolCallId,is_error:event.isError}).catch(()=>{});
 });
}
