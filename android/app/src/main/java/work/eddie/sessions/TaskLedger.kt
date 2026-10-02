package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
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

/**
 * 客户端任务账本 v1：把 Hermes runs 按来源消息分组，渲染成“任务”视图。
 * runs 自带 message_id，可直接关联是哪句话派生的；后端补上 parent_message_id
 *（proposals / sessions）后，分组逻辑零改动升级。详见 docs/TASK_LAYER_CONTRACT.md。
 */

data class LedgerEvent(val label:String,val at:Double)
data class LedgerTask(
 val id:String,
 val title:String,
 val agent:String,
 /** active 进行中 | attention 待核实 | done 已完成 */
 val status:String,
 val statusText:String,
 val updatedAt:Double,
 val messageId:String?,
 val sessionId:String,
 val events:List<LedgerEvent>,
)

private fun ledgerActive(status:String)=status in setOf("running","sending","queued","waiting","approval_required")
private fun ledgerAttention(status:String)=status in setOf("failed","unknown")

private fun runAt(run:JSONObject):Double{
 val u=run.optDouble("updated_at",0.0)
 return if(u>0)u else run.optDouble("created_at",0.0)
}

fun buildLedgerTasks(runs:List<JSONObject>,messages:List<JSONObject>):List<LedgerTask>{
 val groups=runs.groupBy{it.optString("message_id")}
 return groups.mapNotNull{(mid,gruns)->
  if(gruns.isEmpty())return@mapNotNull null
  val sorted=gruns.sortedBy(::runAt)
  val source=messages.firstOrNull{it.optString("id")==mid}
  val last=sorted.last()
  val title=source?.optString("text")?.take(60)?.ifBlank{null}
   ?:last.optString("title").ifBlank{null}
   ?:last.optString("summary").take(60).ifBlank{null}
   ?:"后台任务"
  val status=when{
   sorted.any{ledgerActive(it.optString("status"))}->"active"
   sorted.any{ledgerAttention(it.optString("status"))}->"attention"
   else->"done"
  }
  val statusText=when(status){
   "active"->"进行中"
   "attention"->"待核实"
   else->"已完成"
  }
  LedgerTask(
   id=mid.ifBlank{last.optString("id").ifBlank{sorted.hashCode().toString()}},
   title=title,
   agent=sorted.lastOrNull{it.optString("agent").isNotBlank()}?.optString("agent")?.uppercase().orEmpty().ifBlank{"HERMES"},
   status=status,
   statusText=statusText,
   updatedAt=sorted.maxOf(::runAt),
   messageId=mid.ifBlank{null},
   sessionId=last.optString("session_id"),
   events=sorted.map{run->
    val label=listOf(hermesMessageStatus(run.optString("status")),run.optString("title").take(40)).filter{it.isNotBlank()}.joinToString(" · ")
    LedgerEvent(label.ifBlank{"执行记录"},runAt(run))
   },
  )
 }.sortedWith(compareBy({it.status!="active"},{-it.updatedAt}))
}

/** 活动弹层里的任务分组：进行中置顶，点开展开事件时间线 */
@Composable fun TaskLedgerSection(vm:WorkbenchModel,runs:List<JSONObject>,messages:List<JSONObject>){
 val tasks=vm.taskLedger.array("items").map{t->
  val st=t.optString("status")
  LedgerTask(t.optString("id"),t.optString("title"),t.optString("agent").uppercase(),
   if(st in setOf("running","waiting","dispatching","cancel_requested"))"active" else if(st in setOf("unknown","failed","approval_required"))"attention" else "done",
   when(st){"execution_finished"->"执行结束 · 待验收";"cancel_requested"->"取消待确认";"approval_required"->"待授权";"unknown"->"待核实";"cancelled"->"已停止";else->st},
   t.optDouble("updated_at"),t.optString("message_id"),t.optString("session_id"),
   t.array("events").map{e->LedgerEvent(e.optString("kind")+" · "+e.optString("text"),e.optDouble("at"))})
 }.sortedByDescending{it.updatedAt}
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
     if(task.sessionId.isNotBlank()){
      TextButton(onClick={vm.openId(task.sessionId);vm.externalWorkRoute++},contentPadding=PaddingValues(top=8.dp)){Text("进入执行会话",fontSize=12.sp)}
     }
    }
   }
  }
 }
}
