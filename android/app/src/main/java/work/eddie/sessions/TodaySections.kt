package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONObject

private fun todayRunTitle(run:JSONObject,messages:List<JSONObject>)=run.optString("title").ifBlank{
 run.optString("summary").ifBlank{messages.firstOrNull{it.optString("id")==run.optString("message_id")}
  ?.optString("text")?.take(100).orEmpty().ifBlank{"Pi 任务"}}
}

@Composable fun TodaySections(vm:WorkbenchModel,openActivity:()->Unit){
 val proposals=vm.workProposals.array("items")
 val runs=vm.hermes.array("runs")
 val messages=vm.hermes.array("messages")
 val ledgerTasks=buildLedgerTasks(vm.taskLedger.array("items"),messages)
 val ongoingTasks=ledgerTasks.filter{it.status=="active"}
 val reviewTasks=ledgerTasks.filter{it.status=="attention"&&it.statusText!="待授权"||it.status=="closed"&&it.result.isNotBlank()}
 val signals=vm.signals.array("items")
 val now=System.currentTimeMillis()/1000.0
 val needsApproval=proposals.filter{it.optString("status")=="proposed"&&it.optDouble("expires_at")>now}
 val uncertainProposals=proposals.filter{it.optString("status")=="unknown"}
 val needsReview=runs.filter{it.optString("status") in setOf("waiting","approval_required","unknown","failed")}
 val failedMessages=messages.filter{it.optString("role")=="user"&&it.optString("status")=="failed"}
 val important=signals.filter{it.optString("status")=="reviewed"&&it.optString("priority")=="important"}
 val activeRuns=runs.filter{it.optString("status") in setOf("queued","sending","running")}
 val dispatched=proposals.filter{proposal->
  if(proposal.optString("status")=="dispatching")true
  else if(proposal.optString("status")!="accepted")false
  else{
   val work=vm.allRows.firstOrNull{it.optString("id")==proposal.optString("work_session_id")}
   !vm.allRowsFresh||work?.optString("status") !in setOf("completed","failed","ended","interrupted")
  }
 }

 Surface(Modifier.fillMaxWidth().padding(top=16.dp),shape=RoundedCornerShape(Radii.L),color=Card,border=BorderStroke(1.dp,Line)){
  Column(Modifier.padding(18.dp)){
   Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween){
    Text("待我处理",fontSize=17.sp,fontWeight=FontWeight.SemiBold,color=Ink)
    TextButton(onClick=openActivity){Text("查看活动",fontSize=Type.Caption)}
   }
   if(!vm.workProposalsFresh||!vm.hermesFresh||!vm.signalsFresh)Text("部分条目来自本机缓存，联网后刷新",fontSize=Type.Caption,color=AmberText)
   if(needsApproval.isEmpty()&&uncertainProposals.isEmpty()&&needsReview.isEmpty()&&failedMessages.isEmpty()&&reviewTasks.isEmpty())Text("${if(vm.workProposalsFresh&&vm.hermesFresh)"当前没有待处理项"else"缓存中没有待处理项"}",fontSize=Type.BodySm,color=Muted)
   reviewTasks.take(3).forEach{task->TodayLine("${task.agent} · ${task.statusText}",task.title)}
   needsApproval.take(3).forEach{item->TodayLine("待批准 · ${item.optString("agent").uppercase()}",item.optString("title").ifBlank{"工作建议"})}
   uncertainProposals.take(2).forEach{item->TodayLine("派发结果待核实 · ${item.optString("agent").uppercase()}",item.optString("title").ifBlank{"工作建议"})}
   needsReview.take(3).forEach{run->TodayLine("Pi · ${hermesMessageStatus(run.optString("status"))}",todayRunTitle(run,messages))}
   failedMessages.take(2).forEach{message->TodayLine("Pi · 处理失败",message.optString("text").take(100))}
   if(important.isNotEmpty())Text("重要通知 · 仅供查看",Modifier.padding(top=16.dp),fontSize=Type.Caption,fontWeight=FontWeight.SemiBold,color=Muted)
   important.take(3).forEach{item->TodayLine("巡检结果",item.optString("summary").ifBlank{"通知分析结果已准备好"})}
  }
 }
 Surface(Modifier.fillMaxWidth().padding(top=14.dp),shape=RoundedCornerShape(Radii.L),color=Card,border=BorderStroke(1.dp,Line)){
  Column(Modifier.padding(18.dp)){
   Row(verticalAlignment=Alignment.CenterVertically){
    ComIcon(R.drawable.com_icon_work_v1,null,Modifier.size(24.dp))
    Text("在途工作",Modifier.padding(start=4.dp),fontSize=17.sp,fontWeight=FontWeight.SemiBold,color=Ink)
   }
   if(ongoingTasks.isEmpty())Text(if(vm.taskLedgerFresh)"当前没有在途工作"else"正在同步任务",Modifier.padding(top=9.dp),fontSize=Type.BodySm,color=Muted)
   ongoingTasks.take(3).forEach{task->TodayLine("${if(vm.taskLedgerFresh)""else"上次同步："}${task.agent} · ${task.statusText}",task.title)}
   if(ongoingTasks.isNotEmpty())TextButton(onClick=openActivity){Text("查看任务进度",fontSize=Type.Caption)}
  }
 }
}

@Composable private fun TodayLine(label:String,title:String){
 HorizontalDivider(Modifier.padding(top=12.dp,bottom=10.dp),color=Line)
 Text(label,fontSize=Type.Caption,color=Muted)
 Text(title,Modifier.padding(top=3.dp),fontSize=Type.BodySm,lineHeight=19.sp,color=Ink)
}
