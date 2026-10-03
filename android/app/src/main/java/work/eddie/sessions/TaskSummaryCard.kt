package work.eddie.sessions

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.testTag
import org.json.JSONObject

/**
 * 任务详细总结预览卡：挂在用户消息下方，任务终态后展示。
 *
 * 数据契约（与后端消息协议对齐）：
 * - message.optJSONObject("summary") 不存在时不渲染——绝不编造总结。
 * - summary = {title,status,duration_ms,finished_at,
 *     steps:[{id,title,status,duration_ms,tool,detail}],
 *     outcomes:[String], files:[String]}
 *   status ∈ done|partial|failed；步骤 status ∈ done|failed|skipped|running。
 */

/** done 已完成 | partial 部分完成 | failed 失败 */
data class TaskSummaryStep(val id:String,val title:String,val status:String,val durationMs:Long,val tool:String,val detail:String,val kind:String="task")
data class TaskSummary(val title:String,val status:String,val durationMs:Long,val finishedAt:String,val steps:List<TaskSummaryStep>,val outcomes:List<String>,val files:List<String>,val taskId:String="",val verification:String="")

fun taskSummary(message:JSONObject):TaskSummary?{
 val s=message.optJSONObject("summary")?:return null
 val steps=mutableListOf<TaskSummaryStep>()
 val arr=s.optJSONArray("steps")
 if(arr!=null)for(i in 0 until arr.length()){
  val o=arr.optJSONObject(i)?:continue
  val title=o.optString("title")
  if(title.isBlank())continue
  val id=o.optString("id").ifBlank{"step-$i"}
  steps.add(TaskSummaryStep(id,title,o.optString("status").ifBlank{"unknown"},o.optLong("duration_ms"),o.optString("tool"),o.optString("detail"),agentWorkKind(id,o.optString("kind"))))
 }
 val outcomes=mutableListOf<String>()
 val oarr=s.optJSONArray("outcomes")
 if(oarr!=null)for(i in 0 until oarr.length()){val t=oarr.optString(i);if(t.isNotBlank())outcomes.add(t)}
 val files=mutableListOf<String>()
 val farr=s.optJSONArray("files")
 if(farr!=null)for(i in 0 until farr.length()){val t=farr.optString(i);if(t.isNotBlank())files.add(t)}
 val title=s.optString("title").ifBlank{return null}
 val taskId=s.optString("task_id").takeUnless{agentWorkKind(it,"task")=="phase"}.orEmpty()
 return TaskSummary(title,s.optString("status").ifBlank{"unknown"},s.optLong("duration_ms"),s.optString("finished_at"),steps,outcomes,files,taskId,s.optString("verification_status"))
}

private fun summaryDuration(ms:Long):String{
 if(ms<=0)return ""
 if(ms<1000)return "${ms}毫秒"
 val sec=ms/1000.0
 if(sec<60)return if(sec==sec.toLong().toDouble())"${sec.toLong()}秒" else "${"%.1f".format(sec)}秒"
 val min=(sec/60).toLong();val rest=(sec%60).toLong()
 if(min<60)return if(rest==0L)"${min}分" else "${min}分${rest}秒"
 val h=min/60
 return "${h}小时${min%60}分"
}

fun summaryStatusText(status:String,verification:String="")=when{
 verificationPassed(verification)->"验收通过"
 verification=="unverified"&&status in setOf("done","completed","execution_finished")->"本轮处理结束"
 status=="partial"->"部分执行 · 待验收"
 status in setOf("done","completed","execution_finished")->"执行结束 · 待验收"
 status in setOf("cancelled","interrupted")->"已停止 · 未验收"
 status=="unknown"->"结果待核实"
 status=="running"->"仍在执行"
 status=="failed"->"执行失败"
 else->"状态待核实"
}

private fun summaryStatusColor(status:String,verification:String="")=when{
 verificationPassed(verification)->Success
 status=="failed"->Danger
 status in setOf("partial","unknown")->AmberText
 else->Muted
}

/* A step check marks execution of that step, never goal acceptance. */
@Composable private fun SummaryNodeIcon(status:String){
 val modifier=Modifier.size(20.dp)
 when(status){
  "done","completed","execution_finished"->Icon(Icons.Outlined.CheckCircle,"步骤已执行",modifier,tint=Muted)
  "failed"->Icon(Icons.Outlined.Cancel,"失败",modifier,tint=Danger)
  "skipped"->Icon(Icons.Outlined.RemoveCircleOutline,"跳过",modifier,tint=Faint)
  "running"->Icon(Icons.Outlined.RadioButtonChecked,"进行中",modifier,tint=Ink)
  else->Icon(Icons.Outlined.RadioButtonUnchecked,"待做",modifier,tint=Faint)
 }
}

/** 把总结拼成可复制的纯文本。 */
private fun buildSummaryText(s:TaskSummary):String{
 val sb=StringBuilder()
 sb.append("任务总结：${s.title}（${summaryStatusText(s.status,s.verification)}")
 val d=summaryDuration(s.durationMs)
 if(d.isNotBlank())sb.append(" · 耗时 $d")
 if(s.finishedAt.isNotBlank())sb.append(" · ${s.finishedAt}")
 sb.append("）\n")
 if(s.steps.isNotEmpty()){
  sb.append("步骤：\n")
  s.steps.forEach{step->
   val mark=when(step.status){"done"->"✓";"failed"->"✕";"skipped"->"–";else->"·"}
   sb.append("$mark ${step.title}")
   val sd=summaryDuration(step.durationMs)
   if(sd.isNotBlank())sb.append("（$sd）")
   sb.append("\n")
   if(step.detail.isNotBlank())sb.append("  ${step.detail.trim().lineSequence().take(4).joinToString("\n  ")}\n")
  }
 }
 if(s.outcomes.isNotEmpty()){sb.append("结论：\n");s.outcomes.forEach{sb.append("- $it\n")}}
 if(s.files.isNotEmpty()){sb.append("产物：\n");s.files.forEach{sb.append("- $it\n")}}
 return sb.toString().trimEnd()
}

/**
 * 任务终态的详细总结预览卡。
 * 默认收起总览和所有步骤详情；点按后查看。
 */
@Composable fun TaskSummaryCard(message:JSONObject,onTaskClick:((String)->Unit)?=null){
 val summary=taskSummary(message)?:return
 val context=LocalContext.current
 val haptics=rememberComHaptics()
 val messageId=messageMotionId(message).ifBlank{message.optString("id")}
 var expanded by rememberSaveable(messageId){mutableStateOf(false)}
 var openSteps by rememberSaveable(messageId){mutableStateOf(emptyList<String>())}
 val statusColor=summaryStatusColor(summary.status,summary.verification)
 val meta=buildString{
  append(summaryStatusText(summary.status,summary.verification))
  val d=summaryDuration(summary.durationMs)
  if(d.isNotBlank())append(" · 耗时 $d")
  if(summary.finishedAt.isNotBlank())append(" · ${summary.finishedAt}")
 }
 Surface(Modifier.padding(start=8.dp,top=9.dp).widthIn(max=590.dp).fillMaxWidth(.94f).testTag("task-summary-card-$messageId"),shape=RoundedCornerShape(18.dp),color=ToolSurface,border=BorderStroke(1.dp,Line)){
  Column(Modifier.padding(horizontal=13.dp,vertical=11.dp)){
   Row(Modifier.fillMaxWidth().testTag("task-summary-toggle-$messageId").clickable{expanded=!expanded},verticalAlignment=Alignment.CenterVertically){
    when{
     verificationPassed(summary.verification)->Icon(Icons.Outlined.CheckCircle,"验收通过",Modifier.size(22.dp),tint=Success)
     summary.status=="failed"->Icon(Icons.Outlined.Cancel,"失败",Modifier.size(22.dp),tint=Danger)
     else->Icon(Icons.Outlined.Info,"执行结果",Modifier.size(22.dp),tint=statusColor)
    }
    Column(Modifier.weight(1f).padding(start=10.dp)){
     Text(summary.title,fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=Ink,maxLines=2,overflow=TextOverflow.Ellipsis)
     Text(meta,Modifier.padding(top=2.dp),fontSize=Type.Caption,color=Faint,maxLines=1,overflow=TextOverflow.Ellipsis)
    }
    Icon(if(expanded)Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,if(expanded)"收起" else "展开",Modifier.size(20.dp),tint=Faint)
   }
   AnimatedVisibility(expanded,enter=fadeIn(tween(160)),exit=fadeOut(tween(90))){
    Column(Modifier.padding(top=6.dp)){
     // 步骤时间线
     summary.steps.forEachIndexed{index,step->
      val open=step.id in openSteps
      Row(Modifier.fillMaxWidth()){
       Column(horizontalAlignment=Alignment.CenterHorizontally){
        SummaryNodeIcon(step.status)
        if(index<summary.steps.lastIndex)Box(Modifier.width(2.dp).height(14.dp).padding(top=2.dp)){
         // 连接线
         Surface(Modifier.fillMaxSize(),color=Line,shape=RoundedCornerShape(1.dp)){}
        }
       }
       Column(Modifier.weight(1f).padding(start=8.dp,bottom=if(index<summary.steps.lastIndex)6.dp else 0.dp)){
        Row(Modifier.fillMaxWidth().clickable(enabled=step.detail.isNotBlank()||step.tool.isNotBlank()){
         openSteps=if(open)openSteps-step.id else openSteps+step.id
        },verticalAlignment=Alignment.CenterVertically){
         Text(step.title,Modifier.weight(1f),fontSize=Type.BodySm,color=if(step.status=="done")Muted else Ink,maxLines=2,overflow=TextOverflow.Ellipsis)
         val sd=summaryDuration(step.durationMs)
         if(sd.isNotBlank())Text(sd,Modifier.padding(start=8.dp),fontSize=Type.Caption,color=Faint,maxLines=1)
         if(step.kind=="task"&&onTaskClick!=null)IconButton(onClick={onTaskClick(step.id)},modifier=Modifier.size(30.dp)){Icon(Icons.Outlined.ChevronRight,"查看任务详情",Modifier.size(18.dp),tint=Muted)}
        }
        AnimatedVisibility(open&&(step.detail.isNotBlank()||step.tool.isNotBlank()),enter=fadeIn(tween(140)),exit=fadeOut(tween(80))){
         Surface(Modifier.fillMaxWidth().padding(top=5.dp),shape=RoundedCornerShape(10.dp),color=ChipBg){
          Column(Modifier.padding(horizontal=10.dp,vertical=8.dp)){
           if(step.tool.isNotBlank())Text(step.tool,fontSize=Type.Caption,color=Faint,fontWeight=FontWeight.Medium,maxLines=1,overflow=TextOverflow.Ellipsis)
           if(step.detail.isNotBlank())Text(step.detail,Modifier.padding(top=if(step.tool.isNotBlank())3.dp else 0.dp),fontSize=Type.Caption,lineHeight=16.sp,color=Muted)
          }
         }
        }
       }
      }
     }
     // 关键结论
     if(summary.outcomes.isNotEmpty()){
      HorizontalDivider(Modifier.padding(vertical=8.dp),thickness=1.dp,color=Line)
      Text("关键结论",fontSize=Type.Caption,fontWeight=FontWeight.SemiBold,color=Ink)
      summary.outcomes.forEach{outcome->
       Row(Modifier.fillMaxWidth().padding(top=5.dp),verticalAlignment=Alignment.Top){
        Icon(Icons.Outlined.Check,"结论",Modifier.size(14.dp).padding(top=1.dp),tint=statusColor)
        Text(outcome,Modifier.padding(start=7.dp).weight(1f),fontSize=Type.Caption,lineHeight=16.sp,color=Muted)
       }
      }
     }
     // 产物文件
     if(summary.files.isNotEmpty()){
      HorizontalDivider(Modifier.padding(vertical=8.dp),thickness=1.dp,color=Line)
      ArtifactCards(summary.files.map{JSONObject().put("path",it)})
     }
     // 操作
     HorizontalDivider(Modifier.padding(vertical=8.dp),thickness=1.dp,color=Line)
     Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.End){
      if(summary.taskId.isNotBlank()&&onTaskClick!=null)TextButton(onClick={onTaskClick(summary.taskId)}){Text("查看任务详情",fontSize=Type.Caption,color=Muted)}
      TextButton(onClick={
       val clip=context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
       clip.setPrimaryClip(ClipData.newPlainText("任务总结",buildSummaryText(summary)))
       haptics(HapticCue.Selection)
      },contentPadding=PaddingValues(horizontal=10.dp,vertical=4.dp)){
       Icon(Icons.Outlined.ContentCopy,"复制总结",Modifier.size(15.dp),tint=Muted)
       Text("复制总结",Modifier.padding(start=6.dp),fontSize=Type.Caption,color=Muted,fontWeight=FontWeight.Medium)
      }
     }
    }
   }
  }
 }
}
