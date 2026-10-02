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

private fun proposalSandbox(agent:String,sandbox:String)=when{
 agent=="pi"->"全权限"
 sandbox=="read-only"->"只读"
 sandbox=="workspace-write"->"工作目录内写入"
 sandbox=="danger-full-access"->"全权限"
 else->"权限待核实"
}

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
@Composable fun WorkProposalSection(vm:WorkbenchModel){
 val items=vm.workProposals.array("items")
 HorizontalDivider(Modifier.padding(top=16.dp,bottom=18.dp),color=Line)
 Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween){
  Row(Modifier.weight(1f),verticalAlignment=androidx.compose.ui.Alignment.CenterVertically){
   ComIcon(R.drawable.com_icon_work_v1,null,Modifier.size(24.dp))
   Text("Hermes 工作动态",Modifier.padding(start=4.dp),fontSize=18.sp,fontWeight=FontWeight.SemiBold,color=Ink)
  }
  TextButton(onClick={vm.refreshWorkProposalsNow()},enabled=!vm.workProposalsLoading&&vm.store.token.isNotEmpty()){
   Text(if(vm.workProposalsLoading)"刷新中" else "刷新",fontSize=12.sp)
  }
 }
 Text("请核对目录、指令与权限后批准此任务。刷新不会启动工作。",fontSize=12.sp,lineHeight=18.sp,color=Muted)
 if(!vm.workProposalsFresh&&items.isNotEmpty())Text("以下是上次保存的记录；同步后更新。",Modifier.padding(top=5.dp),fontSize=11.sp,color=AmberText)
 if(vm.workProposalsError.isNotBlank())Text(vm.workProposalsError,Modifier.padding(top=5.dp),fontSize=11.sp,color=AmberText)
 if(vm.workProposalNote.isNotBlank())Text(vm.workProposalNote,Modifier.padding(top=5.dp),fontSize=11.sp,color=AmberText)
 if(items.isEmpty())Text(if(vm.workProposalsLoading)"正在读取工作动态…" else "暂无工作动态",Modifier.padding(top=10.dp),fontSize=13.sp,color=Muted)
 items.take(10).forEach{proposal->
  val id=proposal.optString("id")
  val agent=proposal.optString("agent")
  val status=proposal.optString("status")
  val expired=proposal.optDouble("expires_at")<=System.currentTimeMillis()/1000.0
  Surface(Modifier.fillMaxWidth().padding(top=10.dp),shape=RoundedCornerShape(Radii.L),color=Card,border=BorderStroke(1.dp,Line)){
   Column(Modifier.padding(14.dp)){
    Text(proposal.optString("title").ifBlank{"工作建议"},fontSize=15.sp,fontWeight=FontWeight.SemiBold,color=Ink)
    Text("${agent.uppercase(Locale.ROOT)} · ${proposalSandbox(agent,proposal.optString("sandbox"))} · ${if(expired&&status=="proposed")"已过期" else proposalStatus(status)}",Modifier.padding(top=5.dp),fontSize=11.sp,color=if(agent=="pi"||proposal.optString("sandbox")=="danger-full-access")AmberText else Muted)
    Text("工作目录：${proposal.optString("cwd")}",Modifier.padding(top=6.dp),fontSize=11.sp,lineHeight=17.sp,color=Muted)
    Text("原因：${proposal.optString("reason")}",Modifier.padding(top=7.dp),fontSize=12.sp,lineHeight=18.sp,color=Ink)
    SelectionContainer{Text("交给 ${if(agent=="pi")"Pi" else "Codex"} 的指令：\n${proposal.optString("prompt")}",Modifier.padding(top=7.dp),fontSize=12.sp,lineHeight=18.sp,color=Ink)}
    Text("有效至 ${proposalTime(proposal.optDouble("expires_at"))}",Modifier.padding(top=7.dp),fontSize=11.sp,color=Muted)
    if(status=="proposed"&&!expired){
     TextButton(onClick={vm.approveWorkProposal(id)},enabled=vm.workProposalsFresh&&vm.workProposalBusy.isBlank()){Text("批准此任务权限并启动")}
     TextButton(onClick={vm.rejectWorkProposal(id)},enabled=vm.workProposalsFresh&&vm.workProposalBusy.isBlank()){Text("拒绝")}
    }
    if(status=="unknown"||status=="dispatching")Text("请先去工作页核对实际会话；此卡不会自动重发。",Modifier.padding(top=6.dp),fontSize=11.sp,color=AmberText)
    if(status=="accepted"&&proposal.optString("work_session_id").isNotBlank()){
     TextButton(onClick={vm.openId(proposal.optString("work_session_id"));vm.externalWorkRoute++}){Text("进入工作会话",fontSize=12.sp)}
    }
   }
  }
 }
}
