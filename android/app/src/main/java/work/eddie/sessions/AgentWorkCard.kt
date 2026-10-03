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
import androidx.compose.animation.core.tween
import org.json.JSONObject

/**
 * 聊天内联的 Agent 工作过程卡：任务清单 + 实时动态流。
 *
 * 数据契约（与后端消息协议对齐）：
 * - message.optJSONArray("tasks")：[{id,title,status}]，status ∈ pending|running|done。
 *   后端暂未下发该字段时，任务区直接隐藏——绝不编造进度。
 * - 动态流由客户端根据 phase / active_tool 的变化逐行追加（按 message id 隔离记忆）。
 */

/** pending 待做 | running 进行中 | done 已完成 */
data class AgentWorkTask(val id:String,val title:String,val status:String)

data class AgentWorkEvent(val kind:String,val text:String)

fun agentWorkTasks(message:JSONObject):List<AgentWorkTask>{
 val arr=message.optJSONArray("tasks")?:return emptyList()
 return (0 until arr.length()).mapNotNull{ i->
  val o=arr.optJSONObject(i)?:return@mapNotNull null
  val title=o.optString("title").ifBlank{return@mapNotNull null}
  AgentWorkTask(o.optString("id").ifBlank{"task-$i"},title,o.optString("status").ifBlank{"pending"})
 }
}

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
  "done"->Icon(Icons.Outlined.CheckCircle,"完成",modifier,tint=Success)
  else->ComIcon(R.drawable.com_icon_work_v1,"工作",modifier,tint=Muted)
 }
}

@Composable private fun AgentTaskRow(index:Int,task:AgentWorkTask){
 Row(Modifier.fillMaxWidth().padding(vertical=5.dp),verticalAlignment=Alignment.CenterVertically){
  when(task.status){
   "done"->Icon(Icons.Outlined.CheckCircle,"已完成",Modifier.size(20.dp),tint=Success)
   "running"->Icon(Icons.Outlined.RadioButtonChecked,"进行中",Modifier.size(20.dp),tint=Ink)
   else->Icon(Icons.Outlined.RadioButtonUnchecked,"待做",Modifier.size(20.dp),tint=Faint)
  }
  Text("${index+1}.",Modifier.padding(start=8.dp),fontSize=Type.BodySm,color=Faint,fontWeight=FontWeight.Medium)
  Text(task.title,Modifier.weight(1f).padding(start=4.dp),fontSize=Type.BodySm,color=if(task.status=="done")Muted else Ink,maxLines=2,overflow=TextOverflow.Ellipsis)
 }
}

/**
 * 挂在用户消息下方的 Agent 工作过程卡。
 * 仅在消息处于 queued/sending/running 时由调用方展示；失败/待核实等终态继续走 HermesProgressCard。
 */
@Composable fun AgentWorkCard(message:JSONObject,fresh:Boolean){
 val haptics=rememberComHaptics()
 val messageId=messageMotionId(message).ifBlank{message.optString("id")}
 val phase=message.optString("phase")
 val tool=if(message.isNull("active_tool"))"" else message.optString("active_tool")
 val tasks=agentWorkTasks(message)
 val doneCount=tasks.count{it.status=="done"}
 var lastDoneCount by remember(messageId){mutableIntStateOf(doneCount)}
 LaunchedEffect(doneCount){
  // 关键交互才给震动：任务完成打勾那一下给个轻震动，动态流追加不震。
  if(doneCount>lastDoneCount){haptics(HapticCue.Selection);lastDoneCount=doneCount}
 }
 val events=remember(messageId){mutableStateListOf<AgentWorkEvent>()}
 LaunchedEffect(messageId,phase,tool){
  agentWorkEventFor(phase,tool)?.let{event->
   if(events.lastOrNull()!=event)events.add(event)
  }
 }
 var expanded by rememberSaveable(messageId){mutableStateOf(true)}
 val running=true
 val header=when{
  tasks.isNotEmpty()&&doneCount==tasks.size->"已完成 ${tasks.size} 个任务"
  tasks.isNotEmpty()->"共 ${tasks.size} 个任务，已经完成 $doneCount 个"
  !fresh->"离线记录"
  else->hermesPhaseStatus(phase).ifBlank{"Pi 正在处理"}
 }
 Surface(Modifier.padding(start=8.dp,top=9.dp).widthIn(max=590.dp).fillMaxWidth(.94f),shape=RoundedCornerShape(18.dp),color=ToolSurface,border=BorderStroke(1.dp,Line)){
  Column(Modifier.padding(horizontal=13.dp,vertical=11.dp)){
   Row(Modifier.fillMaxWidth().clickable{expanded=!expanded},verticalAlignment=Alignment.CenterVertically){
    if(running&&fresh)ThinkingDots(Ember) else AgentWorkEventIcon(if(doneCount==tasks.size&&tasks.isNotEmpty())"done" else "work")
    Text(header,Modifier.weight(1f).padding(start=10.dp),fontSize=Type.Caption,fontWeight=FontWeight.SemiBold,color=Ink,maxLines=1,overflow=TextOverflow.Ellipsis)
    Icon(if(expanded)Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,if(expanded)"收起" else "展开",Modifier.size(20.dp),tint=Faint)
   }
   AnimatedVisibility(expanded,enter=fadeIn(tween(160)),exit=fadeOut(tween(90))){
    Column(Modifier.padding(top=4.dp)){
     if(tasks.isNotEmpty()){
      tasks.forEachIndexed{index,task->AgentTaskRow(index,task)}
      if(events.isNotEmpty())HorizontalDivider(Modifier.padding(vertical=6.dp),thickness=1.dp,color=Line)
     }
      events.forEach{event->
       Row(Modifier.fillMaxWidth().padding(vertical=3.dp),verticalAlignment=Alignment.CenterVertically){
        AgentWorkEventIcon(event.kind)
        Text(event.text,Modifier.padding(start=8.dp).weight(1f),fontSize=Type.Caption,lineHeight=16.sp,color=Muted,maxLines=2,overflow=TextOverflow.Ellipsis)
       }
      }
      if(tasks.isEmpty()&&events.isEmpty()){
       Text(if(fresh)"Pi 正在处理这条消息" else "上次同步时 Pi 正在处理",Modifier.padding(top=2.dp),fontSize=Type.Caption,color=Muted)
      }
     }
    }
   }
  }
 }
