package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONObject

private fun todayRunTitle(run:JSONObject,messages:List<JSONObject>)=run.optString("title").ifBlank{
 run.optString("summary").ifBlank{messages.firstOrNull{it.optString("id")==run.optString("message_id")}
  ?.optString("text")?.take(100).orEmpty().ifBlank{"Pi 任务"}}
}

/** 「今天」只收需要用户动作的条目；kind 决定排序与颜色。 */
internal data class TodayItem(
 val kind:String,
 val label:String,
 val title:String,
 val taskId:String="",
 val messageId:String="",
 val signals:Boolean=false,
)

private fun todayKindColor(kind:String)=when(kind){
 "approval","attention"->AmberText
 "failed"->Danger
 "verify"->Ink
 else->Muted
}

/** 按"是否需要决定"排序：需批准 > 需处理 > 失败重试 > 待验收 > 仅供知情。 */
internal fun todayDecisionItems(vm:WorkbenchModel):List<TodayItem>{
 val runs=vm.hermes.array("runs")
 val messages=vm.hermes.array("messages")
 val ledgerTasks=buildLedgerTasks(ledgerTaskRecords(vm,messages),messages)
 val linkedParents=ledgerTasks.mapNotNull{it.messageId}.toSet()
 val signals=vm.signals.array("items")
 val needsReview=runs.filter{it.optString("status") in setOf("waiting","approval_required","unknown","failed")&&it.optString("message_id").isNotBlank()&&it.optString("message_id") !in linkedParents}
 val runParents=needsReview.map{it.optString("message_id")}.toSet()
 val failedMessages=messages.filter{it.optString("role")=="user"&&it.optString("status")=="failed"&&it.optString("id") !in linkedParents&&it.optString("id") !in runParents}
 val important=signals.filter{it.optString("status")=="reviewed"&&it.optString("priority")=="important"}
 val items=mutableListOf<TodayItem>()
 ledgerTasks.filter{ledgerGroup(it) in setOf("decision","verify")}.forEach{task->
  val kind=when{task.rawStatus in setOf("proposed","approval_required")->"approval";ledgerGroup(task)=="verify"->"verify";task.rawStatus=="failed"->"failed";else->"attention"}
  items+=TodayItem(kind,"${task.agent} · ${task.statusText}",task.title,task.id,task.messageId.orEmpty())
 }
 needsReview.forEach{items+=TodayItem("attention","Pi · ${hermesMessageStatus(it.optString("status"))}",todayRunTitle(it,messages),messageId=it.optString("message_id"))}
 failedMessages.forEach{items+=TodayItem("failed","Pi · 处理失败",it.optString("text").take(100),messageId=it.optString("id"))}
 important.forEach{items+=TodayItem("info","巡检结果 · 仅供查看",it.optString("summary").ifBlank{"通知分析结果已准备好"},signals=true)}
 return items.sortedBy{listOf("approval","attention","failed","verify","info").indexOf(it.kind)}
}

internal fun todayOngoingTasks(vm:WorkbenchModel):List<LedgerTask> =
 buildLedgerTasks(ledgerTaskRecords(vm,vm.hermes.array("messages")),vm.hermes.array("messages")).filter{ledgerGroup(it)=="active"}

/** 主页主卡：默认展开、字号最大；每一条都能落到它自己的位置。 */
@Composable fun TodayDecisionCard(vm:WorkbenchModel,openTask:(String,String)->Unit,openAll:()->Unit,openSignals:()->Unit){
 val items=todayDecisionItems(vm)
 val fresh=vm.workProposalsFresh&&vm.hermesFresh&&vm.signalsFresh&&vm.taskLedgerFresh
 Surface(Modifier.fillMaxWidth(),shape=RoundedCornerShape(Radii.L),color=Card,border=BorderStroke(1.dp,Line)){
  Column(Modifier.padding(horizontal=18.dp,vertical=16.dp)){
   Row(verticalAlignment=Alignment.CenterVertically){
    Text("待我处理",fontSize=20.sp,fontWeight=FontWeight.SemiBold,color=Ink)
    if(items.isNotEmpty())Box(Modifier.padding(start=8.dp).background(ChipBg,Radii.Pill).padding(horizontal=9.dp,vertical=2.dp)){
     Text("${items.count{!it.signals}}",fontSize=Type.Caption,fontWeight=FontWeight.SemiBold,color=Ink)
    }
    Spacer(Modifier.weight(1f))
    TextButton(onClick=openAll){Text("全部任务",fontSize=Type.Caption)}
   }
   if(!fresh)Text("部分条目来自本机缓存，联网后刷新",Modifier.padding(top=2.dp),fontSize=Type.Caption,color=AmberText)
   if(items.isEmpty())Text(if(fresh)"当前没有待处理项"else"缓存中没有待处理项",Modifier.padding(top=10.dp),fontSize=Type.BodySm,color=Muted)
   items.take(3).forEachIndexed{index,item->
    if(index>0)HorizontalDivider(Modifier.padding(vertical=2.dp),color=Line)
    TodayActionRow(item){when{
     item.signals->openSignals()
     item.taskId.isNotBlank()->openTask(item.taskId,item.messageId)
     item.messageId.isNotBlank()->vm.returnToHermes(item.messageId)
     else->openAll()
    }}
   }
   if(items.size>3)TextButton(onClick=openAll,modifier=Modifier.fillMaxWidth()){
    Text("查看其余 ${items.size-3} 项",fontSize=Type.Caption)
   }
  }
 }
}

@Composable private fun TodayActionRow(item:TodayItem,onClick:()->Unit){
 Column(Modifier.fillMaxWidth().testTag("today-item-${item.taskId.ifBlank{item.messageId.ifBlank{"signals"}}}").clip(RoundedCornerShape(Radii.M)).clickable(onClick=onClick).padding(horizontal=8.dp,vertical=10.dp)){
  Row(verticalAlignment=Alignment.CenterVertically){
   Text(item.label,Modifier.weight(1f),fontSize=Type.Caption,color=todayKindColor(item.kind),maxLines=1,overflow=TextOverflow.Ellipsis)
   Text(when{item.signals->"查看通知 ›";item.taskId.isNotBlank()->"查看任务 ›";else->"核对原消息 ›"},fontSize=Type.Caption,color=Faint)
  }
  Text(item.title,Modifier.padding(top=3.dp),fontSize=Type.BodySm,lineHeight=19.sp,color=Ink,maxLines=2,overflow=TextOverflow.Ellipsis)
 }
}

/** 在途工作降为一行摘要；完整台账只在「任务」页。 */
@Composable fun TodayWorkLine(vm:WorkbenchModel,openTasks:()->Unit){
 val tasks=todayOngoingTasks(vm)
 Surface(onClick=openTasks,modifier=Modifier.fillMaxWidth().testTag("today-ongoing"),shape=RoundedCornerShape(Radii.L),color=Card,border=BorderStroke(1.dp,Line)){
  Row(Modifier.padding(horizontal=18.dp,vertical=16.dp),verticalAlignment=Alignment.CenterVertically){
   ComIcon(R.drawable.com_icon_work_v1,null,Modifier.size(22.dp))
   Column(Modifier.weight(1f).padding(start=10.dp)){
    Text("在途工作 · ${tasks.size}",fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=Ink)
    Text(
     if(tasks.isEmpty())if(vm.taskLedgerFresh)"当前没有在途工作" else "正在同步任务"
     else tasks.joinToString(" / "){it.title}.take(64),
     Modifier.padding(top=2.dp),fontSize=Type.Caption,color=Muted,maxLines=1,overflow=TextOverflow.Ellipsis)
   }
   ComIcon(R.drawable.com_icon_chevron_v1,"查看任务进度",Modifier.size(20.dp))
  }
 }
}
