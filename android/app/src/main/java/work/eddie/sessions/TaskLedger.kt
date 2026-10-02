package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
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
)

fun ledgerStatus(status:String):Pair<String,String> = when(status){
 "running"->"active" to "执行中"
 "sending","dispatching"->"active" to "派发中"
 "queued"->"active" to "已受理 · 排队中"
 "waiting"->"active" to "等待工作器"
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
 LedgerTask(
  id=t.optString("id").ifBlank{t.optString("run_id").ifBlank{"unlinked-$index"}},
  title=t.optString("title").ifBlank{source?.optString("text")?.take(60).orEmpty().ifBlank{"后台任务"}},
  agent=t.optString("agent").uppercase().ifBlank{"工作器未知"},
  status=state.first,statusText=state.second,updatedAt=at,messageId=parent.ifBlank{null},
  sessionId=t.optString("session_id").ifBlank{t.optString("work_session_id")},
  events=t.array("events").map{e->LedgerEvent(e.optString("kind")+" · "+e.optString("text"),e.optDouble("at"))},
  result=t.optString("result"))
}.sortedWith(compareBy({it.status!="active"},{-it.updatedAt}))

/** 活动弹层里的任务分组：进行中置顶，点开展开事件时间线 */
@Composable fun TaskLedgerSection(vm:WorkbenchModel,runs:List<JSONObject>,messages:List<JSONObject>){
 val tasks=buildLedgerTasks(vm.taskLedger.array("items"),messages)
 var expanded by remember{mutableStateOf<String?>(null)}
 HorizontalDivider(Modifier.padding(top=4.dp,bottom=14.dp),color=Line)
 Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically){
  Text("任务",fontSize=18.sp,fontWeight=FontWeight.SemiBold,color=Ink)
  Text("${tasks.count{it.status=="active"}} 进行中 · ${tasks.size} 全部",fontSize=11.sp,color=Muted)
 }
 if(tasks.isEmpty()){
  Text("暂无任务记录",Modifier.padding(top=10.dp),fontSize=13.sp,color=Muted)
  return
 }
 tasks.forEach{task->
  Surface(onClick={expanded=if(expanded==task.id)null else task.id},Modifier.fillMaxWidth().padding(top=10.dp),shape=RoundedCornerShape(Radii.L),color=Card,border=BorderStroke(1.dp,Line)){
   Column(Modifier.padding(14.dp)){
    Row(verticalAlignment=Alignment.CenterVertically){
     if(task.status=="active")StatusDot(PiGreen) else Box(Modifier.size(6.dp).background(if(task.status=="attention")AmberText else Faint,CircleShape))
     Text(task.title,Modifier.weight(1f).padding(start=8.dp),fontSize=14.sp,fontWeight=FontWeight.Medium,color=Ink,maxLines=2,overflow=TextOverflow.Ellipsis)
    }
    Text("${task.agent} · ${task.statusText} · ${if(task.updatedAt>0)relTime(task.updatedAt) else "时间未知"}",Modifier.padding(top=4.dp,start=14.dp),fontSize=11.sp,color=Muted)
    if(expanded==task.id){
     if(!vm.workProposalsFresh)Text("离线缓存，同步后才能操作",fontSize=12.sp,color=Muted)
     Text(vm.taskControlNote,fontSize=12.sp,color=Muted)
     var instruction by remember(task.id){mutableStateOf("")}
     if(task.status=="active"){
      OutlinedTextField(value=instruction,onValueChange={instruction=it},label={Text("补充约束")},modifier=Modifier.fillMaxWidth())
      Row{
       TextButton(onClick={vm.taskCommand(task.id,instruction)},enabled=instruction.isNotBlank()&&vm.workProposalsFresh&&vm.taskControlBusy.isBlank()){Text("提交指令")}
       TextButton(onClick={vm.taskCommand(task.id,"",true)},enabled=vm.workProposalsFresh&&vm.taskControlBusy.isBlank()){Text("请求取消")}
      }
     }
     task.events.forEach{ev->
      Row(Modifier.padding(top=8.dp),verticalAlignment=Alignment.CenterVertically){
       Box(Modifier.size(5.dp).background(Line,CircleShape))
       Column(Modifier.padding(start=8.dp)){
        Text(ev.label,fontSize=12.sp,color=Ink,maxLines=2,overflow=TextOverflow.Ellipsis)
        if(ev.at>0)Text(relTime(ev.at),fontSize=10.sp,color=Faint)
       }
      }
     }
     if(task.result.isNotBlank())SelectionContainer{Text(task.result,Modifier.padding(top=10.dp),fontSize=12.sp,color=Ink)}
     if(task.sessionId.isNotBlank()){
      TextButton(onClick={vm.openId(task.sessionId);vm.externalWorkRoute++},contentPadding=PaddingValues(top=8.dp)){Text("进入执行会话",fontSize=12.sp)}
     }
    }
   }
  }
 }
}
