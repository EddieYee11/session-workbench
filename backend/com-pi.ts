/** Com transport only: never uses a WeChat lane, gateway session or model-visible token. */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createHash } from "node:crypto";

let deliveredContext: any;
function context(): any { return deliveredContext ?? JSON.parse(readFileSync(process.env.COM_PI_CONTEXT!, "utf8")); }
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
 bookkeeping_search:Type.Object({date:Type.Optional(Type.String({description:"北京时间单日 YYYY-MM-DD；缺年份时按上下文 current_date 的当前年份"})),start_date:Type.Optional(Type.String()),end_date:Type.Optional(Type.String()),amount:Type.Optional(Type.Number({description:"金额，单位元，精确匹配"})),keyword:Type.Optional(Type.String()),transaction_type:Type.Optional(Type.Union([Type.Literal("expense"),Type.Literal("income"),Type.Literal("all")])),limit:Type.Optional(Type.Integer({minimum:1,maximum:50}))}),
 task_submit:Type.Object({request_id:Type.String(),title:Type.String(),prompt:Type.String(),agent:Type.Union([Type.Literal("pi"),Type.Literal("claude"),Type.Literal("codex")]),relative_cwd:Type.String(),sandbox:Type.Optional(Type.String({default:"danger-full-access",description:"Com全部执行器使用最高权限。旧read-only/workspace-write字段只保留审计，不再限制执行。"})),source_quote:Type.String(),completion_condition:Type.String(),goal_id:Type.Optional(Type.String()),plan_node_id:Type.Optional(Type.String()),depends_on:Type.Optional(Type.Array(Type.String())),acceptance_criteria:Type.Optional(Type.Array(Type.Object({id:Type.String(),description:Type.String()})))}),
 task_verify:Type.Object({task_id:Type.String(),checks:Type.Array(Type.Object({type:Type.String(),path:Type.Optional(Type.String()),value:Type.Optional(Type.String()),command:Type.Optional(Type.String()),criterion_id:Type.Optional(Type.String())})),quality_review:Type.Optional(Type.Boolean())}),
 task_resume:Type.Object({task_id:Type.String(),request_id:Type.String()}),
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
 bookkeeping_search:"直接只读查询真实历史账本，按北京时间日期、金额或备注筛选。用户给日期和金额时，首轮同时传date和amount。date与start_date/end_date二选一，默认支出；用户问哪笔消费时直接查，不派任务。返回真实ID、日期、金额、分类、备注和账户；找不到或结果截断如实说明。recent只有最近30笔，历史查询用本工具。",
 task_submit:"仅在独立并行、耗时或专门能力有益时委派；Pi 主线可直接工作，不强制派活。Pi、Claude、Codex均最高权限danger-full-access，旧只读约束仅审计。source_quote 引用真实用户消息，选项续答沿已关联原交办。最高权限不扩大真实业务交办，不重放未知副作用。已受理不代表已执行。",
 task_verify:"通过真实文件/测试检查验收结束的原任务。checks type=file_exists/file_contains/tests，tests 使用项目测试命令，不根据文本完成通过。",
 task_resume:"在用户明确要求继续时恢复原任务，沿已保存的任务和执行者会话继续，不另建重复任务。",
 task_merge:"仅用于确实存在历史workspace_copy的已验收任务，按项目串行合入。当前最高权限任务直接在原目录工作，验收后直接交付，无需本工具。基线/Syncthing 未通过时保留补丁暂停。",
 task_status:"查询现有任务真实执行、输入送达、产物和验收状态。",
 task_send:"复用原任务补充当前真实要求；constraint_type支持read_only/preserve_style/forbid_path/note。旧read_only只作审计，Com最高权限下不再限制执行；来源和未知副作用去重仍生效。",
 task_cancel:"停止用户指定的原任务，实际终止后才显示已停止。",
 goal_upsert:"记录用户明确交办的长期目标和可执行下一步，沿原授权推进。愿望只能讨论。",
 goal_status:"查看目标状态和原授权。",
 goal_update:"更新同一原授权下目标的下一步。任务已结束未验收时设 waiting_acceptance 并清空下一步，不能重复派发。目标完成需真实验收与证据。",
 propose_work:"提交具体不可逆删除动作供用户批准；不能把愿望变为授权。",
 react_to_user_message:"按本轮 reaction 参数为用户消息附表情。",
};
export default function (pi:ExtensionAPI) {
 // The extension receives message_start before the next model/tool cycle. A
 // staged supplement must not overwrite the running user's authorization on ACK.
 pi.on("message_start",async(event)=>{
  if(event.message.role!=="user") return;
  deliveredContext={}; // Unbound/forged input cannot inherit an older authorization.
  const content:any=event.message.content;
  const text=typeof content==="string"?content:Array.isArray(content)?content.filter((b:any)=>b.type==="text").map((b:any)=>b.text).join("\n"):"";
  const marker=/^\[Com input:([^\]\n]+)\]\n/.exec(text);
  if(!marker) return;
  const digest=createHash("sha256").update(marker[1]).digest("hex");
  const record=JSON.parse(readFileSync(join(dirname(process.env.COM_PI_CONTEXT!),"inputs",digest+".json"),"utf8"));
  if(record.request_id!==marker[1]) throw new Error("Com input source mismatch");
  deliveredContext=record.context;
 });
 for (const [name, parameters] of Object.entries(schemas)) {
  pi.registerTool({name,label:name,description:descriptions[name],parameters,
   async execute(_id,args){const result = await call(name,args);return {content:[{type:"text",text:JSON.stringify(result)}],details:result};},
  });
 }
 pi.on("session_start",async (_event,ctx)=>{
  // A CLI --tools allowlist also excludes business extensions. Operational
  // Com processes activate their actually loaded tools through Pi's API;
  // tool-free probes and judges keep their existing restricted tool set.
  if(process.env.COM_PI_OPERATIONAL_TOOLS==="1") pi.setActiveTools(pi.getAllTools().map(t=>t.name));
  await call("loaded",{tools:pi.getActiveTools()},{}).catch(()=>{});
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
