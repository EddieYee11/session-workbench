package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.testTag
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
 val rawStatus:String="",val completionCondition:String="",val stage:String="",val latestStep:String="",
 val blockReason:String="",
 val sourceSessionId:String="",val sourceMessageId:String="",
)


fun ledgerEventText(event:JSONObject):String{
 val raw=event.optString("text")
 return runCatching{val data=JSONObject(raw);data.optString("tool").ifBlank{if(data.has("usage"))"已记录 Token，金额未知"else raw}}.getOrDefault(raw)
}

fun ledgerEventLabel(kind:String):String=when(kind){
 "tool.started"->"工具开始";"tool.completed"->"工具结束";"tool.failed"->"工具失败"
 "input.delivered"->"输入进入上下文";"verification.passed"->"验收通过"
 "workspace.isolated"->"工作副本已准备";"workspace.merged"->"已合入项目";"artifact.created"->"产物已保存"
 "execution_unknown"->"执行结果待核实";"usage"->"执行用量"
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

fun ledgerStatus(status:String,verification:String=""):Pair<String,String> = if(status in setOf("done","completed","execution_finished")&&verificationPassed(verification))"closed" to "验收通过" else when(status){
 "running"->"active" to "执行中"
 "sending","dispatching"->"active" to "派发中"
 "queued"->"active" to "已受理 · 排队中"
 "waiting"->"active" to "等待你的授权或回应"
 "cancel_requested"->"active" to "取消待确认"
 "approval_required","proposed"->"attention" to "待授权"
 "failed"->"attention" to "执行失败"
 "unknown"->"attention" to "执行状态待核实"
 "paused"->"attention" to "已暂停 · 等待继续"
 "done"->"closed" to "执行结束 · 待验收"
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
 val state=ledgerStatus(t.optString("status"),if(taskAcceptancePassed(t))"passed" else "").let{pair->if(t.optString("stage").isNotBlank())pair.first to t.optString("stage") else pair}
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
  events=t.array("events").map{e->LedgerEvent(listOf(ledgerEventLabel(e.optString("kind")),ledgerEventText(e)).filter{it.isNotBlank()}.joinToString(" · "),e.optDouble("at"))},
  result=t.optString("result"),goal=goal,directory=t.optString("cwd"),
  constraints=(t.optJSONArray("constraints")?:org.json.JSONArray()).let{a->(0 until a.length()).map{a.optString(it)}},
  inputs=t.array("inputs"),source=source?.optString("text").orEmpty().ifBlank{t.optJSONObject("authorization")?.optString("source_quote").orEmpty()},
  scope=if(t.optString("execution_scope")=="business-read")"业务任务" else "工作任务",
  executionInstructions=instructions,rawStatus=t.optString("status"),completionCondition=t.optString("completion_condition"),
  stage=t.optString("stage"),latestStep=t.optString("latest_step"),
  blockReason=t.optString("block_reason").takeUnless{it=="null"}.orEmpty().trim(),
  sourceSessionId=t.optString("source_session_id").takeUnless{it=="null"}.orEmpty().ifBlank{if(source!=null)"personal-main"else""},
  sourceMessageId=t.optString("source_message_id").takeUnless{it=="null"}.orEmpty().ifBlank{if(source!=null)parent else""})
}.sortedWith(compareBy({it.status!="active"},{-it.updatedAt}))

/** Only accepted results are completed. Finished executions have their own review group. */
fun ledgerGroup(task:LedgerTask):String=when{
 task.rawStatus in setOf("waiting","approval_required","proposed","paused","unknown","failed")->"decision"
 task.statusText=="验收通过"->"done"
 task.rawStatus in setOf("execution_finished","completed","done")->"verify"
 task.status=="active"->"active"
 task.rawStatus in setOf("cancelled","interrupted","rejected","expired")->"ended"
 else->"decision"
}

/** One identity across live ledger, message cards, and older proposal-only records. */
internal fun ledgerTaskRecords(vm:WorkbenchModel,messages:List<JSONObject>):List<JSONObject>{
 val records=(vm.taskLedger.array("items")+messages.flatMap{it.array("linked_tasks")}).distinctBy{it.optString("id")}.toMutableList()
 val known=records.map{it.optString("id")}.toMutableSet()
 vm.workProposals.array("items").forEach{proposal->
  val id=proposal.optString("id")
  if(id.isNotBlank()&&known.add(id)){
   val record=JSONObject(proposal.toString())
   when(record.optString("status")){
    "proposed"->if(record.optDouble("expires_at")<=System.currentTimeMillis()/1000.0)record.put("status","expired")
    "accepted"->record.put("status","unknown").put("stage","已派发 · 任务状态待核实")
   }
   records+=record
  }
 }
 return records
}

private val taskFilters=listOf("all" to "全部","decision" to "待你决定","active" to "执行中","verify" to "待验收","done" to "已完成","ended" to "已结束")

@Composable private fun TaskFilterChips(vm:WorkbenchModel,tasks:List<LedgerTask>){
 Row(Modifier.fillMaxWidth().padding(top=4.dp).horizontalScroll(rememberScrollState()),horizontalArrangement=Arrangement.spacedBy(8.dp)){
  taskFilters.forEach{(key,label)->
   val count=if(key=="all")tasks.size else tasks.count{ledgerGroup(it)==key}
   val selected=vm.taskFilter==key
   Surface(onClick={vm.taskFilter=key},modifier=Modifier.testTag("task-filter-$key"),shape=Radii.Pill,color=if(selected)Ink else ChipBg){
    Text("$label $count",Modifier.padding(horizontal=14.dp,vertical=7.dp),fontSize=Type.Caption,fontWeight=if(selected)FontWeight.SemiBold else FontWeight.Normal,color=if(selected)Color.White else Muted)
   }
  }
 }
}

/** 活动弹层里的任务分组：进行中置顶，点开展开事件时间线 */
@Composable fun TaskLedgerSection(vm:WorkbenchModel,runs:List<JSONObject>,messages:List<JSONObject>,taskId:String="",filtered:Boolean=false){
 val allTasks=buildLedgerTasks(ledgerTaskRecords(vm,messages),messages)
 val tasks=allTasks.filter{if(taskId.isNotBlank())it.id==taskId else !filtered||vm.taskFilter=="all"||ledgerGroup(it)==vm.taskFilter}
 var expanded by rememberSaveable(taskId){mutableStateOf<String?>(taskId.takeIf{it.isNotBlank()})}
 HorizontalDivider(Modifier.padding(top=4.dp,bottom=14.dp),color=Line)
 if(!filtered||taskId.isNotBlank())Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically){
  Text(if(taskId.isNotBlank())"交办与进度" else "任务",fontSize=18.sp,fontWeight=FontWeight.SemiBold,color=Ink)
  Text(if(taskId.isNotBlank())"" else "${allTasks.count{ledgerGroup(it)=="active"}} 执行中 · ${allTasks.size} 全部",fontSize=Type.Caption,color=Muted)
 }
 if(filtered&&taskId.isBlank())TaskFilterChips(vm,allTasks)
 if(tasks.isEmpty()){
  Text(if(taskId.isNotBlank())"这项任务详情正在同步" else if(filtered&&vm.taskFilter!="all")"这个分类中没有任务" else if(vm.taskLedgerFresh)"还没有后台任务" else "任务正在同步",Modifier.padding(top=10.dp),fontSize=Type.BodySm,color=Muted)
  Text("在主对话里交办事情，任务会在这里显示。点开任务可看进度、补充要求或停止执行。",Modifier.padding(top=6.dp),fontSize=Type.Caption,lineHeight=19.sp,color=Muted)
  return
 }
 tasks.forEach{task->
  Surface(onClick={if(filtered&&taskId.isBlank())vm.openTaskDetail(task.id,task.messageId.orEmpty()) else expanded=if(expanded==task.id)null else task.id},Modifier.fillMaxWidth().padding(top=10.dp).testTag("task-ledger-${task.id}"),shape=RoundedCornerShape(Radii.L),color=Card,border=BorderStroke(1.dp,Line)){
   Column(Modifier.padding(14.dp)){
    Row(verticalAlignment=Alignment.CenterVertically){
     if(ledgerGroup(task)=="active"&&vm.taskLedgerFresh)StatusDot(PiGreen) else Box(Modifier.size(6.dp).background(if(ledgerGroup(task)=="decision"&&vm.taskLedgerFresh)AmberText else Faint,CircleShape))
     Text(task.title,Modifier.weight(1f).padding(start=8.dp),fontSize=Type.BodySm,fontWeight=FontWeight.Medium,color=Ink,maxLines=2,overflow=TextOverflow.Ellipsis)
    }
    Text("${if(vm.taskLedgerFresh)"" else "上次同步："}${task.agent} · ${task.statusText}${if(task.scope=="业务任务")" · ${task.scope}" else ""} · ${if(task.updatedAt>0)relTime(task.updatedAt) else "时间未知"}",Modifier.padding(top=4.dp,start=14.dp),fontSize=Type.Caption,color=Muted)
    if(task.blockReason.isNotBlank())Text("等待原因：${task.blockReason}",Modifier.padding(top=6.dp,start=14.dp),fontSize=Type.Caption,lineHeight=19.sp,color=AmberText)
    if(filtered&&taskId.isBlank())Text("查看任务 ›",Modifier.padding(top=6.dp,start=14.dp),fontSize=Type.Caption,color=Muted)
    if(expanded==task.id){
     var executionDetails by rememberSaveable(task.id){mutableStateOf(false)}
     if(!vm.taskLedgerFresh)Text("离线缓存，同步后才能操作",fontSize=Type.Caption,color=AmberText)
     Text("${task.scope} · ${task.directory.substringAfterLast('/').ifBlank{"目录待核对"}}",Modifier.padding(top=8.dp),fontSize=Type.Caption,color=Muted)
     if(task.goal.isNotBlank())Text(task.goal,Modifier.padding(top=10.dp),fontSize=Type.BodySm,lineHeight=20.sp,color=Ink,maxLines=3,overflow=TextOverflow.Ellipsis)
     if(task.completionCondition.isNotBlank())Text("完成条件：${task.completionCondition}",Modifier.padding(top=8.dp),fontSize=Type.Caption,color=Muted)
     if(task.stage.isNotBlank())Text("当前阶段：${task.stage}",Modifier.padding(top=6.dp),fontSize=Type.Caption,color=Muted)
     if(task.latestStep.isNotBlank())Text("最近一步：${task.latestStep}",Modifier.padding(top=6.dp),fontSize=Type.Caption,color=Muted)
     if(task.source.isNotBlank())Text("交办原文：${task.source}",Modifier.padding(top=8.dp),fontSize=Type.Caption,color=Muted,maxLines=3,overflow=TextOverflow.Ellipsis)
     task.constraints.forEach{Text("约束 · $it",Modifier.padding(top=6.dp),fontSize=Type.Caption,color=Ink)}
     if(vm.taskControlTarget==task.id&&vm.taskControlNote.isNotBlank())Text(vm.taskControlNote,Modifier.padding(top=10.dp),fontSize=Type.Caption,color=Muted)
     if(task.rawStatus in setOf("proposed","approval_required")){
      val proposal=vm.workProposals.array("items").firstOrNull{it.optString("id")==task.id}
      if(proposal!=null){
       Text("原因：${proposal.optString("reason")}",Modifier.padding(top=8.dp),fontSize=Type.Caption,color=Muted)
       proposal.optJSONObject("actual_action")?.takeIf{it.length()>0}?.let{Text("批准的具体动作：${it.toString()}",Modifier.padding(top=8.dp),fontSize=Type.Caption,color=AmberText)}
       WorkProposalActions(vm,proposal)
       var proposalDetails by rememberSaveable(task.id){mutableStateOf(false)}
       TextButton(onClick={proposalDetails=!proposalDetails}){Text(if(proposalDetails)"收起执行指令"else"查看完整执行指令",fontSize=Type.Caption)}
       if(proposalDetails)SelectionContainer{Text("交给 ${if(proposal.optString("agent")=="pi")"Pi"else"Codex"} 的指令：\n${proposal.optString("prompt")}",fontSize=Type.Caption,lineHeight=19.sp,color=Ink)}
      }
      else{
       Text("授权建议正在同步；允许与拒绝仅针对这项任务。",Modifier.padding(top=8.dp),fontSize=Type.Caption,color=AmberText)
       TextButton(onClick={vm.refreshWorkProposalsNow()}){Text("刷新授权建议")}
      }
     }
     if(task.sessionId.isNotBlank()&&task.status=="active")NativeTaskApprovals(vm,task.sessionId)
     if(task.rawStatus=="paused")TextButton(onClick={vm.resumeTask(task.id)},enabled=vm.taskLedgerFresh&&vm.taskControlBusy.isBlank()){Text("继续这项任务")}
     var instruction by remember(task.id){mutableStateOf("")}
     if(task.status=="active"||task.rawStatus in setOf("proposed","approval_required")){
      OutlinedTextField(value=instruction,onValueChange={instruction=it},label={Text("补充约束")},modifier=Modifier.fillMaxWidth())
      Row{
       TextButton(onClick={vm.taskCommand(task.id,instruction)},enabled=instruction.isNotBlank()&&vm.taskLedgerFresh&&vm.taskControlBusy.isBlank()){Text("补充要求")}
       TextButton(onClick={vm.taskCommand(task.id,"",true)},enabled=vm.taskLedgerFresh&&vm.taskControlBusy.isBlank()){Text("请求停止")}
      }
     }
     if(task.sessionId.isNotBlank()){
      TextButton(onClick={vm.openId(task.sessionId);vm.externalWorkRoute++},contentPadding=PaddingValues(top=8.dp)){Text("进入执行会话",fontSize=Type.Caption)}
     }
     if(task.sourceSessionId.isNotBlank()&&task.sourceMessageId.isNotBlank())TextButton(onClick={
      if(task.sourceSessionId=="personal-main")vm.returnToHermes(task.sourceMessageId)
      else {vm.openId(task.sourceSessionId);vm.queryInSession="";vm.targetMessage=task.sourceMessageId;vm.externalWorkRoute++}
     },modifier=Modifier.testTag("task-source-${task.id}"),contentPadding=PaddingValues(top=8.dp)){Text("回到交办消息",fontSize=Type.Caption)}
     if(task.result.isNotBlank())SelectionContainer{Text(task.result,Modifier.padding(top=10.dp),fontSize=Type.Caption,color=Ink)}
     task.inputs.forEach{input->
      Text(ledgerDeliveryLabel(input.optString("state"))+" · "+input.optString("text"),Modifier.padding(top=8.dp),fontSize=Type.Caption,color=Muted)
      if(input.optString("error").isNotBlank())Text(input.optString("error"),fontSize=Type.Caption,color=AmberText)
     }
     task.events.forEach{ev->
      Row(Modifier.padding(top=8.dp),verticalAlignment=Alignment.CenterVertically){
       Box(Modifier.size(5.dp).background(Line,CircleShape))
       Column(Modifier.padding(start=8.dp)){
        Text(ev.label,fontSize=Type.Caption,color=Ink)
        if(ev.at>0)Text(relTime(ev.at),fontSize=Type.Micro,color=Faint)
       }
      }
     }
     if(task.executionInstructions.isNotBlank()||task.directory.isNotBlank()){
      TextButton(onClick={executionDetails=!executionDetails},contentPadding=PaddingValues(top=8.dp)){
       Text(if(executionDetails)"收起执行详情"else"执行详情",fontSize=Type.Caption,color=Muted)
      }
      if(executionDetails){
       if(task.directory.isNotBlank())Text("${task.scope} · ${task.directory}",Modifier.padding(top=4.dp),fontSize=Type.Caption,color=Muted)
       if(task.source.isNotBlank())SelectionContainer{Text("交办原文：${task.source}",Modifier.padding(top=8.dp),fontSize=Type.Caption,color=Muted)}
       if(task.executionInstructions.isNotBlank())SelectionContainer{Text(task.executionInstructions,Modifier.padding(top=8.dp),fontSize=Type.Caption,lineHeight=19.sp,color=Muted)}
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
    if(vm.taskDetailId.isNotBlank())IconButton(onClick=back){Icon(Icons.Outlined.ArrowBack,"返回上一页")}
    Text(if(vm.taskDetailId.isBlank())"任务" else "任务详情",Modifier.weight(1f),fontSize=23.sp,fontWeight=FontWeight.SemiBold,color=Ink)
    IconButton(onClick={vm.refreshWorkProposalsNow()},enabled=!vm.workProposalsLoading){Icon(Icons.Outlined.Refresh,"刷新任务")}
   }
   Text(if(vm.taskLedgerFresh)"任务在 Mac mini 上执行，关闭手机后仍继续。" else "${vm.taskLedgerError.ifBlank{"连接中，正在读取任务状态"}}",Modifier.padding(top=6.dp,bottom=14.dp),fontSize=Type.Caption,color=Muted)
   if(vm.workProposalNote.isNotBlank())Text(vm.workProposalNote,Modifier.padding(bottom=8.dp),fontSize=Type.Caption,color=Muted)
   TaskLedgerSection(vm,vm.hermes.array("runs"),vm.hermes.array("messages"),vm.taskDetailId,filtered=true)
  }
 }
}

/** Notification reviews have their own page; they do not create work tasks. */
@Composable fun SignalActivityPage(vm:WorkbenchModel,back:()->Unit){
 LaunchedEffect(Unit){if(vm.active&&vm.store.token.isNotBlank())vm.refreshSignalsNow()}
 Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal=20.dp,vertical=12.dp),horizontalAlignment=Alignment.CenterHorizontally){
  Column(Modifier.widthIn(max=820.dp).fillMaxWidth()){
   Row(verticalAlignment=Alignment.CenterVertically){
    IconButton(onClick=back){Icon(Icons.Outlined.ArrowBack,"返回今天")}
    Text("通知巡检",fontSize=23.sp,fontWeight=FontWeight.SemiBold,color=Ink)
   }
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
  Text("执行器请求本次授权",Modifier.padding(top=10.dp),fontSize=Type.Caption,fontWeight=FontWeight.SemiBold,color=AmberText)
  Approval(vm,approval)
 }
 if(error.isNotBlank())Text(error,Modifier.padding(top=8.dp),fontSize=Type.Caption,color=AmberText)
}
