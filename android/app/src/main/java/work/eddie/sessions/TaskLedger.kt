package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONObject

/** Durable task IDs define identity; source messages only provide parent linkage. */

data class LedgerEvent(val label:String,val at:Double)
data class LedgerTask(
 val id:String,
 val title:String,
 val agent:String,
 /** active 进行中 | attention 待处理/核实 | closed 已结束（不等于验收通过） */
 val status:String,
 val statusText:String,
 val updatedAt:Double,
 val messageId:String?,
 val sessionId:String,
 val events:List<LedgerEvent>,
 val result:String="",
 val goal:String="",
 val directory:String="",
 val constraints:List<String> = emptyList(),
 val inputs:List<JSONObject> = emptyList(),
 val source:String="",
 val scope:String="",
 val executionInstructions:String="",
)

fun ledgerEventLabel(kind:String):String=when(kind){
 "created"->"任务已创建";"authorized"->"已授权";"started"->"开始执行"
 "queued"->"进入队列";"constraint"->"约束已更新";"input_accepted"->"补充已受理"
 "input_delivered"->"补充已送达";"cancel_requested"->"已请求停止"
 "cancelled"->"执行已停止";"execution_finished"->"执行结束，待验收"
 "failed"->"执行失败";"unknown"->"结果待核实";"rejected"->"已拒绝"
 else->kind.replace('_',' ')
}

fun ledgerDeliveryLabel(state:String):String=when(state){
 "accepted","queued"->"已受理 · 待送达";"pending_start"->"已保存 · 开始时送达"
 "sending"->"正在送达";"delivered"->"已送达 · 执行结果待核对"
 "worker_queued"->"执行器已接收 · 等待下一回合";"unknown"->"送达待核实"
 "failed"->"送达失败";"unsupported"->"当前会话不支持补充"
 "blocked_authorization"->"等待授权";"blocked_state"->"状态不允许送达"
 else->"状态待核实"
}

fun ledgerStatus(status:String):Pair<String,String> = when(status){
 "running"->"active" to "执行中"
 "sending","dispatching"->"active" to "派发中"
 "queued"->"active" to "已受理 · 排队中"
 "waiting"->"active" to "等待你的授权或回应"
 "cancel_requested"->"active" to "取消待确认"
 "approval_required","proposed"->"attention" to "待授权"
 "failed"->"attention" to "执行失败"
 "unknown"->"attention" to "执行状态待核实"
 "execution_finished","completed"->"closed" to "执行结束 · 待验收"
 "cancelled","interrupted"->"closed" to "已停止 · 未完成验收"
 "rejected"->"closed" to "已拒绝 · 未执行"
 "expired"->"closed" to "授权已过期"
 "ended"->"attention" to "会话结束 · 任务结果待核实"
 else->"attention" to "未知状态 · 待核实"
}

fun ledgerParent(task:JSONObject):String = listOf("message_id","parent_message_id","origin_message_id")
 .map{task.optString(it).takeUnless{value->value=="null"}.orEmpty()}.firstOrNull{it.isNotBlank()}.orEmpty()

fun buildLedgerTasks(records:List<JSONObject>,messages:List<JSONObject>):List<LedgerTask> = records.mapIndexed{index,t->
 val parent=ledgerParent(t)
 val source=messages.firstOrNull{it.optString("id")==parent}
 val state=ledgerStatus(t.optString("status"))
 val at=t.optDouble("updated_at",0.0).takeIf{it>0}?:t.optDouble("created_at",0.0)
 val instructions=t.optString("prompt")
 val goal=t.optString("goal").ifBlank{
  instructions.substringAfter("任务说明：\n",instructions)
   .substringBefore("\n\n完成条件：").substringBefore("\n\n").trim()
 }.ifBlank{t.optString("title")}
 LedgerTask(
  id=t.optString("id").ifBlank{t.optString("run_id").ifBlank{"unlinked-$index"}},
  title=t.optString("title").ifBlank{source?.optString("text")?.take(60).orEmpty().ifBlank{"后台任务"}},
  agent=t.optString("agent").uppercase().ifBlank{"工作器未知"},
  status=state.first,statusText=state.second,updatedAt=at,messageId=parent.ifBlank{null},
  sessionId=t.optString("session_id").ifBlank{t.optString("work_session_id")},
  events=t.array("events").map{e->LedgerEvent(listOf(ledgerEventLabel(e.optString("kind")),e.optString("text")).filter{it.isNotBlank()}.joinToString(" · "),e.optDouble("at"))},
  result=t.optString("result"),goal=goal,directory=t.optString("cwd"),
  constraints=(t.optJSONArray("constraints")?:org.json.JSONArray()).let{a->(0 until a.length()).map{a.optString(it)}},
  inputs=t.array("inputs"),source=source?.optString("text").orEmpty(),
  scope=when(t.optString("sandbox")){"read-only"->"只读检查";"workspace-write"->"项目内修改";"danger-full-access"->"按任务授权执行";else->"授权范围待核对"},
  executionInstructions=instructions)
}.sortedWith(compareBy({it.status!="active"},{-it.updatedAt}))

/** 活动弹层里的任务分组：进行中置顶，点开展开事件时间线 */
@Composable fun TaskLedgerSection(vm:WorkbenchModel,runs:List<JSONObject>,messages:List<JSONObject>){
 val tasks=buildLedgerTasks(vm.taskLedger.array("items"),messages)
 var expanded by rememberSaveable{mutableStateOf<String?>(null)}
 HorizontalDivider(Modifier.padding(top=4.dp,bottom=14.dp),color=Line)
 Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically){
  Text("任务",fontSize=18.sp,fontWeight=FontWeight.SemiBold,color=Ink)
  Text("${tasks.count{it.status=="active"}} 进行中 · ${tasks.size} 全部",fontSize=11.sp,color=Muted)
 }
 if(tasks.isEmpty()){
  Text(if(vm.taskLedgerFresh)"还没有后台任务" else "任务正在同步",Modifier.padding(top=10.dp),fontSize=13.sp,color=Muted)
  Text("在主对话里交办事情，任务会在这里显示。点开任务可看进度、补充要求或停止执行。",Modifier.padding(top=6.dp),fontSize=12.sp,lineHeight=19.sp,color=Muted)
  return
 }
 tasks.forEach{task->
  Surface(onClick={expanded=if(expanded==task.id)null else task.id},Modifier.fillMaxWidth().padding(top=10.dp),shape=RoundedCornerShape(Radii.L),color=Card,border=BorderStroke(1.dp,Line)){
   Column(Modifier.padding(14.dp)){
    Row(verticalAlignment=Alignment.CenterVertically){
     if(task.status=="active"&&vm.taskLedgerFresh)StatusDot(PiGreen) else Box(Modifier.size(6.dp).background(if(task.status=="attention"&&vm.taskLedgerFresh)AmberText else Faint,CircleShape))
     Text(task.title,Modifier.weight(1f).padding(start=8.dp),fontSize=14.sp,fontWeight=FontWeight.Medium,color=Ink,maxLines=2,overflow=TextOverflow.Ellipsis)
    }
    Text("${if(vm.taskLedgerFresh)"" else "上次同步："}${task.agent} · ${task.statusText} · ${if(task.updatedAt>0)relTime(task.updatedAt) else "时间未知"}",Modifier.padding(top=4.dp,start=14.dp),fontSize=11.sp,color=Muted)
    if(expanded==task.id){
     var executionDetails by rememberSaveable(task.id){mutableStateOf(false)}
     if(!vm.taskLedgerFresh)Text("离线缓存，同步后才能操作",fontSize=12.sp,color=AmberText)
     Text("${task.scope} · ${task.directory.substringAfterLast('/').ifBlank{"目录待核对"}}",Modifier.padding(top=8.dp),fontSize=11.sp,color=Muted)
     if(task.goal.isNotBlank())Text(task.goal,Modifier.padding(top=10.dp),fontSize=13.sp,lineHeight=20.sp,color=Ink,maxLines=3,overflow=TextOverflow.Ellipsis)
     if(task.source.isNotBlank())Text("交办原文：${task.source}",Modifier.padding(top=8.dp),fontSize=12.sp,color=Muted,maxLines=3,overflow=TextOverflow.Ellipsis)
     task.constraints.forEach{Text("约束 · $it",Modifier.padding(top=6.dp),fontSize=12.sp,color=Ink)}
     if(vm.taskControlTarget==task.id&&vm.taskControlNote.isNotBlank())Text(vm.taskControlNote,Modifier.padding(top=10.dp),fontSize=12.sp,color=Muted)
     if(task.statusText=="待授权"){
      val proposal=vm.workProposals.array("items").firstOrNull{it.optString("id")==task.id}
      if(proposal!=null)WorkProposalActions(vm,proposal)
      else{
       Text("授权建议正在同步；允许与拒绝仅针对这项任务。",Modifier.padding(top=8.dp),fontSize=12.sp,color=AmberText)
       TextButton(onClick={vm.refreshWorkProposalsNow()}){Text("刷新授权建议")}
      }
     }
     if(task.sessionId.isNotBlank()&&task.status=="active")NativeTaskApprovals(vm,task.sessionId)
     var instruction by remember(task.id){mutableStateOf("")}
     if(task.status=="active"||task.statusText=="待授权"){
      OutlinedTextField(value=instruction,onValueChange={instruction=it},label={Text("补充约束")},modifier=Modifier.fillMaxWidth())
      Row{
       TextButton(onClick={vm.taskCommand(task.id,instruction)},enabled=instruction.isNotBlank()&&vm.taskLedgerFresh&&vm.taskControlBusy.isBlank()){Text("补充要求")}
       TextButton(onClick={vm.taskCommand(task.id,"",true)},enabled=vm.taskLedgerFresh&&vm.taskControlBusy.isBlank()){Text("请求停止")}
      }
     }
     if(task.sessionId.isNotBlank()){
      TextButton(onClick={vm.openId(task.sessionId);vm.externalWorkRoute++},contentPadding=PaddingValues(top=8.dp)){Text("进入执行会话",fontSize=12.sp)}
     }
     if(task.result.isNotBlank())SelectionContainer{Text(task.result,Modifier.padding(top=10.dp),fontSize=12.sp,color=Ink)}
     task.inputs.forEach{input->
      Text(ledgerDeliveryLabel(input.optString("state"))+" · "+input.optString("text"),Modifier.padding(top=8.dp),fontSize=12.sp,color=Muted)
      if(input.optString("error").isNotBlank())Text(input.optString("error"),fontSize=11.sp,color=AmberText)
     }
     task.events.forEach{ev->
      Row(Modifier.padding(top=8.dp),verticalAlignment=Alignment.CenterVertically){
       Box(Modifier.size(5.dp).background(Line,CircleShape))
       Column(Modifier.padding(start=8.dp)){
        Text(ev.label,fontSize=12.sp,color=Ink)
        if(ev.at>0)Text(relTime(ev.at),fontSize=10.sp,color=Faint)
       }
      }
     }
     if(task.executionInstructions.isNotBlank()||task.directory.isNotBlank()){
      TextButton(onClick={executionDetails=!executionDetails},contentPadding=PaddingValues(top=8.dp)){
       Text(if(executionDetails)"收起执行详情"else"执行详情",fontSize=12.sp,color=Muted)
      }
      if(executionDetails){
       if(task.directory.isNotBlank())Text("${task.scope} · ${task.directory}",Modifier.padding(top=4.dp),fontSize=11.sp,color=Muted)
       if(task.source.isNotBlank())SelectionContainer{Text("交办原文：${task.source}",Modifier.padding(top=8.dp),fontSize=12.sp,color=Muted)}
       if(task.executionInstructions.isNotBlank())SelectionContainer{Text(task.executionInstructions,Modifier.padding(top=8.dp),fontSize=12.sp,lineHeight=19.sp,color=Muted)}
      }
     }
    }
   }
  }
 }
}

@Composable fun TaskActivityPage(vm:WorkbenchModel,back:()->Unit){
 Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal=20.dp,vertical=12.dp),horizontalAlignment=Alignment.CenterHorizontally){
  Column(Modifier.widthIn(max=820.dp).fillMaxWidth()){
   Row(verticalAlignment=Alignment.CenterVertically){
    IconButton(onClick=back){Icon(Icons.Outlined.ArrowBack,"返回主对话")}
    Text("任务与活动",Modifier.weight(1f),fontSize=23.sp,fontWeight=FontWeight.SemiBold,color=Ink)
    IconButton(onClick={vm.refreshWorkProposalsNow()},enabled=!vm.workProposalsLoading){Icon(Icons.Outlined.Refresh,"刷新任务")}
   }
   Text(if(vm.taskLedgerFresh)"任务在 Mac mini 上执行，关闭手机后仍继续。" else "${vm.taskLedgerError.ifBlank{"连接中，正在读取任务状态"}}",Modifier.padding(top=6.dp,bottom=14.dp),fontSize=12.sp,color=Muted)
   WorkProposalSection(vm,pendingOnly=true)
   TaskLedgerSection(vm,vm.hermes.array("runs"),vm.hermes.array("messages"))
   WorkProposalSection(vm,historyOnly=true)
   SignalActivitySection(vm)
  }
 }
}


/** Native approvals stay bound to this task's execution session. */
@Composable private fun NativeTaskApprovals(vm:WorkbenchModel,sid:String){
 var approvals by remember(sid){mutableStateOf<List<JSONObject>>(emptyList())}
 var error by remember(sid){mutableStateOf("")}
 LaunchedEffect(sid,vm.active,vm.taskLedgerFresh){
  if(!vm.active||!vm.taskLedgerFresh)return@LaunchedEffect
  while(true){
   try{
    val live=vm.store.request("/sessions/${vm.enc(sid)}/live")
    approvals=live.array("approvals").filter{it.optString("sid")==sid}
    error=""
   }catch(e:kotlinx.coroutines.CancellationException){throw e}
    catch(e:Exception){error="执行器授权暂未同步，请进入执行会话核对。"}
   kotlinx.coroutines.delay(3000)
  }
 }
 if(vm.taskLedgerFresh)approvals.forEach{approval->
  Text("执行器请求本次授权",Modifier.padding(top=10.dp),fontSize=12.sp,fontWeight=FontWeight.SemiBold,color=AmberText)
  Approval(vm,approval)
 }
 if(error.isNotBlank())Text(error,Modifier.padding(top=8.dp),fontSize=11.sp,color=AmberText)
}
