package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

private fun proposalTime(seconds:Double):String=if(seconds<=0)"未知" else runCatching{
 Instant.ofEpochMilli((seconds*1000).toLong()).atZone(ZoneId.of("Asia/Shanghai"))
  .format(DateTimeFormatter.ofPattern("M月d日 HH:mm",Locale.CHINA))
}.getOrDefault("未知")

/** Task authorization is explicit and independent from refresh. */
private fun proposalStatus(status:String)=when(status){
 "proposed"->"待授权"
 "dispatching"->"正在派发"
 "accepted"->"已启动"
 "unknown"->"派发结果待核实"
 "rejected"->"已拒绝"
 "expired"->"已过期"
 else->"状态待核实"
}

/**
 * Hermes 工作动态与任务级授权。
 * 这里只做透明记录：让用户看到 Hermes 做了什么、为什么、进行到哪一步。
 */
@Composable fun WorkProposalSection(vm:WorkbenchModel,pendingOnly:Boolean=false,historyOnly:Boolean=false){
 val allItems=vm.workProposals.array("items")
 val items=allItems.filter{when{pendingOnly->it.optString("status")=="proposed";historyOnly->it.optString("status")!="proposed";else->true}}
  .sortedBy{it.optString("status")!="proposed"}
 HorizontalDivider(Modifier.padding(top=16.dp,bottom=18.dp),color=Line)
 Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween){
  Row(Modifier.weight(1f),verticalAlignment=androidx.compose.ui.Alignment.CenterVertically){
   ComIcon(R.drawable.com_icon_work_v1,null,Modifier.size(24.dp))
   Text(if(pendingOnly)"待授权 · ${items.size}"else if(historyOnly)"授权记录"else"Pi 工作动态",Modifier.padding(start=4.dp),fontSize=18.sp,fontWeight=FontWeight.SemiBold,color=Ink)
  }
  TextButton(onClick={vm.refreshWorkProposalsNow()},enabled=!vm.workProposalsLoading&&vm.store.token.isNotEmpty()){
   Text(if(vm.workProposalsLoading)"刷新中" else "刷新",fontSize=Type.Caption)
  }
 }
 Text("请核对目录与指令后批准此任务。刷新不会启动工作。",fontSize=Type.Caption,lineHeight=18.sp,color=Muted)
 if(!vm.workProposalsFresh&&items.isNotEmpty())Text("以下是上次保存的记录；同步后更新。",Modifier.padding(top=5.dp),fontSize=Type.Caption,color=AmberText)
 if(vm.workProposalsError.isNotBlank())Text(vm.workProposalsError,Modifier.padding(top=5.dp),fontSize=Type.Caption,color=AmberText)
 if(vm.workProposalNote.isNotBlank())Text(vm.workProposalNote,Modifier.padding(top=5.dp),fontSize=Type.Caption,color=AmberText)
 if(items.isEmpty())Text(if(vm.workProposalsLoading)"正在读取工作动态…" else "暂无工作动态",Modifier.padding(top=10.dp),fontSize=Type.BodySm,color=Muted)
 items.forEach{proposal->WorkProposalCard(vm,proposal)}
}

/** Shared by the main conversation and task page, always using the same proposal ID. */
@Composable fun WorkProposalCard(vm:WorkbenchModel,proposal:JSONObject){
  val id=proposal.optString("id")
  val agent=proposal.optString("agent")
  val status=proposal.optString("status")
  val expired=proposal.optDouble("expires_at")<=System.currentTimeMillis()/1000.0
  Surface(Modifier.fillMaxWidth().padding(top=10.dp),shape=RoundedCornerShape(Radii.L),color=if(status=="proposed"&&!expired)AmberBg else Card,border=BorderStroke(1.dp,if(status=="proposed"&&!expired)AmberLine else Line)){
   Column(Modifier.padding(14.dp)){
    Text(proposal.optString("title").ifBlank{"工作建议"},fontSize=Type.Body,fontWeight=FontWeight.SemiBold,color=Ink)
    Text("${agent.uppercase(Locale.ROOT)} · ${if(expired&&status=="proposed")"已过期" else proposalStatus(status)}",Modifier.padding(top=5.dp),fontSize=Type.Caption,color=Muted)
    Text("工作目录：${proposal.optString("cwd")}",Modifier.padding(top=6.dp),fontSize=Type.Caption,lineHeight=17.sp,color=Muted)
    Text("原因：${proposal.optString("reason")}",Modifier.padding(top=7.dp),fontSize=Type.Caption,lineHeight=18.sp,color=Ink)
    WorkProposalActions(vm,proposal)
    var details by remember(id){mutableStateOf(false)}
    TextButton(onClick={details=!details}){Text(if(details)"收起执行指令" else "查看完整执行指令",fontSize=Type.Caption)}
    if(details)SelectionContainer{Text("交给 ${if(agent=="pi")"Pi" else "Codex"} 的指令：\n${proposal.optString("prompt")}",Modifier.padding(top=7.dp),fontSize=Type.Caption,lineHeight=18.sp,color=Ink)}
    Text("有效至 ${proposalTime(proposal.optDouble("expires_at"))}",Modifier.padding(top=7.dp),fontSize=Type.Caption,color=Muted)

    if(status=="unknown"||status=="dispatching")Text("请先去工作页核对实际会话；此卡不会自动重发。",Modifier.padding(top=6.dp),fontSize=Type.Caption,color=AmberText)
    if(status=="accepted"&&proposal.optString("work_session_id").isNotBlank()){
     TextButton(onClick={vm.openId(proposal.optString("work_session_id"));vm.externalWorkRoute++}){Text("进入工作会话",fontSize=Type.Caption)}
    }
   }
  }
}

/** The same scoped authorization controls appear in the queue and matching task detail. */
@Composable fun WorkProposalActions(vm:WorkbenchModel,proposal:JSONObject){
 val id=proposal.optString("id")
 if(proposal.optString("status")!="proposed")return
 val expired=proposal.optDouble("expires_at")<=System.currentTimeMillis()/1000.0
 if(expired){Text("授权已过期，请在主对话中重新确认工作建议。",fontSize=Type.Caption,color=AmberText);return}
 val enabled=vm.workProposalsFresh&&vm.workProposalBusy.isBlank()&&vm.store.token.isNotBlank()
 val haptics=rememberComHaptics()
 if(!vm.workProposalsFresh)Text("离线记录，同步后才能允许或拒绝。",Modifier.padding(top=8.dp),fontSize=Type.Caption,color=AmberText)
 Row(Modifier.fillMaxWidth().padding(top=10.dp),horizontalArrangement=Arrangement.spacedBy(10.dp)){
  Button(onClick={haptics(HapticCue.Commit);vm.approveWorkProposal(id)},enabled=enabled,modifier=Modifier.weight(1f),shape=Radii.Pill){
   Text(if(vm.workProposalBusy==id)"正在核对授权…"else"允许并启动",fontSize=Type.BodySm)
  }
  OutlinedButton(onClick={haptics(HapticCue.Reject);vm.rejectWorkProposal(id)},enabled=enabled,modifier=Modifier.weight(1f),shape=Radii.Pill){Text("拒绝",fontSize=Type.BodySm)}
 }
 if(vm.workProposalBusy==id)Text("授权请求处理中，请等候实际回执。",Modifier.padding(top=4.dp),fontSize=Type.Caption,color=Muted)
}
