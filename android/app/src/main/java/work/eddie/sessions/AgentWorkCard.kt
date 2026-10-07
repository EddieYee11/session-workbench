package work.eddie.sessions

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.testTag
import androidx.compose.animation.core.tween
import org.json.JSONObject

/**
 * 聊天内联的 Agent 工作过程卡：任务清单 + 实时动态流。
 *
 * 数据契约（与后端消息协议对齐）：
 * - message.optJSONArray("tasks")：[{id,title,status}]，status ∈ pending|running|done|failed。
 *   后端暂未下发该字段时，任务区直接隐藏——绝不编造进度。
 * - work_events 是服务器保存的真实记录；缺失时只显示当前阶段的单行观察。
 */

/** pending 待做 | running 进行中 | done 已完成 | failed 失败 */
data class AgentWorkTask(val id:String,val title:String,val status:String,val kind:String="task",val verification:String="",val stage:String="",val accepted:Boolean=false)

data class AgentWorkEvent(val kind:String,val text:String,val id:String="",val at:Double=0.0)

fun verificationPassed(status:String)=status in setOf("passed","verified")
fun workspaceDeliveryAccepted(sandbox:String,hasCopy:Boolean,runId:String,mergedRunId:String):Boolean =
 sandbox!="workspace-write"||!hasCopy||(runId.isNotBlank()&&runId!="null"&&runId==mergedRunId)
fun agentWorkKind(id:String,kind:String):String=if(id.substringAfterLast(':') in setOf("think","reply"))"phase" else kind.ifBlank{"task"}
fun agentEventDisplayText(text:String,status:String):String=when(status){
 "failed"->if(text.startsWith("正在使用 "))"工具调用失败 · ${text.removePrefix("正在使用 ")}" else "$text · 失败"
 "unknown","uncertain"->if(text.startsWith("正在使用 "))"工具结果待核实 · ${text.removePrefix("正在使用 ")}" else "$text · 结果待核实"
 "done","completed","execution_finished"->if(text.startsWith("正在使用 "))"工具调用结束 · ${text.removePrefix("正在使用 ")}" else text
 else->text
}
fun taskAcceptancePassed(task:JSONObject):Boolean{
 if(task.has("acceptance_passed"))return task.optBoolean("acceptance_passed")
 if(!verificationPassed(task.optString("verification_status")))return false
 if(task.optString("stage").isNotBlank()&&task.optString("stage")!="验收通过")return false
 val copy=listOf("workspace_copy","work_copy","copy").firstOrNull{!task.isNull(it)&&task.optString(it).isNotBlank()}
 return workspaceDeliveryAccepted(task.optString("sandbox"),copy!=null,task.optString("run_id"),task.optString("merged_run_id"))
}
fun agentTaskStatusText(status:String,kind:String="task",verification:String="",id:String=""):String=when{
 kind=="phase"->when(status){
  "done","completed","execution_finished"->if(id.substringAfterLast(':')=="reply")"回复已生成" else "已处理"
  "running"->"正在处理"
  "failed"->"处理失败"
  "pending","queued"->"待处理"
  else->"阶段待核实"
 }
 verificationPassed(verification)->"已验收"
 status in setOf("done","completed","execution_finished")->if(kind=="tool")"工具已执行" else "执行结束 · 待验收"
 status in setOf("running","executing")->"执行中"
 status in setOf("queued","pending","sending","dispatching")->"排队中"
 status=="failed"->"执行失败"
 status in setOf("waiting","approval_required","proposed")->"等待你回应"
 status in setOf("cancelled","interrupted")->"已停止 · 未验收"
 else->"状态待核实"
}

fun agentWorkTasks(message:JSONObject):List<AgentWorkTask>{
 val arr=message.optJSONArray("tasks")?:return emptyList()
 return (0 until arr.length()).mapNotNull{ i->
  val o=arr.optJSONObject(i)?:return@mapNotNull null
  val title=o.optString("title").ifBlank{return@mapNotNull null}
  val id=o.optString("id").ifBlank{"task-$i"}
  val kind=agentWorkKind(id,o.optString("kind"))
  AgentWorkTask(id,title,o.optString("status").ifBlank{"unknown"},kind,o.optString("verification_status"),o.optString("stage"),kind=="task"&&taskAcceptancePassed(o))
 }
}

fun agentWorkEvents(message:JSONObject):List<AgentWorkEvent> = message.array("work_events").mapNotNull{event->
 val text=event.optString("text").ifBlank{event.optString("title")}
 val rawKind=event.optString("kind","work")
 val status=event.optString("status").ifBlank{when{
  rawKind.endsWith(".failed")->"failed"
  rawKind.endsWith(".completed")->"done"
  else->""
 }}
 val kind=when{
  status=="failed"||rawKind.endsWith(".failed")->"failed"
  status in setOf("unknown","uncertain")->"unknown"
  agentWorkKind(event.optString("id"),rawKind)=="phase"->if(event.optString("id").substringAfterLast(':')=="reply")"write" else "analyze"
  status in setOf("done","completed","execution_finished")||rawKind.endsWith(".completed")->"done"
  else->rawKind
 }
 if(text.isBlank())null else AgentWorkEvent(kind,event.optString("display_text").ifBlank{agentEventDisplayText(text,status)},event.optString("id"),event.optDouble("at",0.0))
}.distinctBy{it.id.ifBlank{"${it.kind}:${it.at}:${it.text}"}}

private fun agentToolEvent(tool:String):AgentWorkEvent?{
 if(tool.isBlank())return null
 val label=when{
  tool.endsWith("personal_overview")->"正在读取日历与账本概览"
  tool.endsWith("recent_work_sessions")->"正在核对工作会话"
  tool.endsWith("propose_work")->"正在准备工作建议"
  tool.endsWith("work_proposal_status")->"正在核对工作建议"
  else->"正在使用 ${tool.take(46)}"
 }
 val kind=when{
  "search" in tool||"web" in tool||"browse" in tool->"search"
  "git" in tool||"pull" in tool||"fetch" in tool->"code"
  "edit" in tool||"write" in tool||"apply" in tool||"patch" in tool->"edit"
  else->"tool"
 }
 return AgentWorkEvent(kind,label)
}

/** 当前 phase / tool 对应的一行动动态；无事可报时返回 null。 */
fun agentWorkEventFor(phase:String,tool:String):AgentWorkEvent?=when{
 tool.isNotBlank()->agentToolEvent(tool)
 phase=="thinking"->AgentWorkEvent("analyze","分析用户请求内容")
 phase in setOf("responding","replying","streaming")->AgentWorkEvent("write","正在撰写回复")
 phase in setOf("executing")->AgentWorkEvent("work","努力工作中")
 else->null
}

@Composable private fun AgentWorkEventIcon(kind:String){
 val modifier=Modifier.size(18.dp)
 when(kind){
  "analyze"->ComIcon(R.drawable.com_icon_activity_v1,"分析",modifier,tint=Muted)
  "search"->Icon(Icons.Outlined.Search,"搜索",modifier,tint=Muted)
  "code"->Icon(Icons.Outlined.Code,"代码",modifier,tint=Muted)
  "edit"->Icon(Icons.Outlined.Edit,"修改",modifier,tint=Muted)
  "write"->Icon(Icons.Outlined.Draw,"撰写",modifier,tint=Muted)
  "done"->Icon(Icons.Outlined.CheckCircle,"工具调用结束",modifier,tint=Muted)
  "failed"->Icon(Icons.Outlined.ErrorOutline,"调用失败",modifier,tint=Danger)
  "unknown"->Icon(Icons.Outlined.HelpOutline,"结果待核实",modifier,tint=AmberText)
  else->Icon(Icons.Outlined.RadioButtonChecked,"执行记录",modifier,tint=Muted)
 }
}

@Composable private fun AgentTaskRow(index:Int,task:AgentWorkTask,onTaskClick:((String)->Unit)?){
 val label=if(task.kind=="phase")agentTaskStatusText(task.status,task.kind,id=task.id) else task.stage.ifBlank{agentTaskStatusText(task.status,task.kind,if(task.accepted)"passed" else "")}
 Row(Modifier.fillMaxWidth().then(if(task.kind=="task"&&onTaskClick!=null)Modifier.clickable{onTaskClick(task.id)} else Modifier).padding(vertical=5.dp).testTag("agent-task-${task.id}"),verticalAlignment=Alignment.CenterVertically){
  when{
   task.accepted->Icon(Icons.Outlined.CheckCircle,"已验收",Modifier.size(20.dp),tint=Success)
   task.status in setOf("done","completed","execution_finished")->Icon(Icons.Outlined.CheckCircle,label,Modifier.size(20.dp),tint=Muted)
   task.status=="running"->Icon(Icons.Outlined.RadioButtonChecked,"进行中",Modifier.size(20.dp),tint=Ink)
   task.status=="failed"->Icon(Icons.Outlined.Close,"失败",Modifier.size(20.dp),tint=Danger)
   else->Icon(Icons.Outlined.RadioButtonUnchecked,"待做",Modifier.size(20.dp),tint=Faint)
  }
  Text("${index+1}.",Modifier.padding(start=8.dp),fontSize=Type.BodySm,color=Faint,fontWeight=FontWeight.Medium)
  Column(Modifier.weight(1f).padding(start=4.dp)){
   Text(task.title,fontSize=Type.BodySm,color=Ink,maxLines=2,overflow=TextOverflow.Ellipsis)
   Text(label,fontSize=Type.Micro,color=Muted)
  }
  if(task.kind=="task"&&onTaskClick!=null)Icon(Icons.Outlined.ChevronRight,"查看任务详情",Modifier.size(18.dp),tint=Faint)
 }
}

/**
 * 挂在用户消息下方的 Agent 工作过程卡。
 * 有真实步骤或事件就展示；没有服务器记录时仅显示接收状态。
 */
@Composable fun AgentWorkCard(message:JSONObject,fresh:Boolean,onTaskClick:((String)->Unit)?=null){
 val messageId=messageMotionId(message).ifBlank{message.optString("id")}
 val phase=message.optString("phase")
 val tool=if(message.isNull("active_tool"))"" else message.optString("active_tool")
 val tasks=agentWorkTasks(message)
 val doneCount=tasks.count{it.accepted}
 val taskCount=tasks.count{it.kind=="task"}
 val toolCount=tasks.count{it.kind=="tool"}
 // Reconnect snapshots can contain older acceptance transitions; they never trigger haptics.
 // History comes from durable server events. A single live observation is a fallback.
 val events=agentWorkEvents(message).ifEmpty{if(fresh&&!message.optBoolean("local"))listOfNotNull(agentWorkEventFor(phase,tool)) else emptyList()}
 var expanded by rememberSaveable(messageId){mutableStateOf(false)}
 val running=message.optString("status") in setOf("queued","sending","running")||tasks.any{it.status in setOf("queued","sending","running","dispatching")}
 val header=when{
  !fresh->"离线记录"
  message.optBoolean("local")->if(message.optString("status")=="unknown")"接收结果待核实" else "已保存 · 正在发送"
  taskCount>0->"$taskCount 项任务 · $doneCount 项已验收"
  toolCount>0->"$toolCount 次工具调用"
  tasks.isNotEmpty()->hermesPhaseStatus(phase).ifBlank{"本轮处理记录"}
  else->hermesPhaseStatus(phase).ifBlank{"Hermes 正在处理"}
 }
 Surface(Modifier.padding(start=8.dp,top=9.dp).widthIn(max=590.dp).fillMaxWidth(.94f).testTag("agent-work-card-$messageId"),shape=RoundedCornerShape(18.dp),color=ToolSurface,border=BorderStroke(1.dp,Line)){
  Column(Modifier.padding(horizontal=13.dp,vertical=11.dp)){
   Row(Modifier.fillMaxWidth().testTag("agent-work-toggle-$messageId").clickable{expanded=!expanded},verticalAlignment=Alignment.CenterVertically){
    if(running&&fresh)ThinkingDots(Ember) else AgentWorkEventIcon(if(doneCount==tasks.size&&tasks.isNotEmpty())"done" else "work")
    Text(header,Modifier.weight(1f).padding(start=10.dp),fontSize=Type.Caption,fontWeight=FontWeight.SemiBold,color=Ink,maxLines=1,overflow=TextOverflow.Ellipsis)
    Icon(if(expanded)Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,if(expanded)"收起" else "展开",Modifier.size(20.dp),tint=Faint)
   }
   AnimatedVisibility(expanded,enter=fadeIn(tween(160)),exit=fadeOut(tween(90))){
    Column(Modifier.padding(top=4.dp)){
     if(tasks.isNotEmpty()){
      tasks.forEachIndexed{index,task->AgentTaskRow(index,task,onTaskClick)}
      if(events.isNotEmpty())HorizontalDivider(Modifier.padding(vertical=6.dp),thickness=1.dp,color=Line)
     }
      events.forEach{event->
       Row(Modifier.fillMaxWidth().padding(vertical=3.dp),verticalAlignment=Alignment.CenterVertically){
        AgentWorkEventIcon(event.kind)
        Text(event.text,Modifier.padding(start=8.dp).weight(1f),fontSize=Type.Caption,lineHeight=16.sp,color=Muted,maxLines=2,overflow=TextOverflow.Ellipsis)
       }
      }
      if(tasks.isEmpty()&&events.isEmpty()){
       Text(if(message.optBoolean("local"))"服务器接收回执到达后，才显示执行进度。" else if(fresh)"等待执行动态" else "上次同步的执行记录",Modifier.padding(top=2.dp),fontSize=Type.Caption,color=Muted)
      }
     }
    }
   }
  }
 }
