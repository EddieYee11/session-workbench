package work.eddie.sessions

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Handyman

/** Runtime priority keeps a new queued message from hiding the turn actually executing. */
fun avatarActiveMessageIndex(states:List<Pair<String,String>>):Int? = states.indices
 .filter{states[it].first in setOf("running","executing","responding","streaming","thinking","sending","waiting","approval_required","queued")}
 .minWithOrNull(compareBy<Int>{index->
  val (status,phase)=states[index]
  when{
   status in setOf("running","executing","responding","streaming","thinking")->0
   status=="sending"&&phase in setOf("executing","tool","responding","replying","streaming")->1
   status=="sending"->2
   status in setOf("waiting","approval_required")->3
   else->4
  }
 }.thenByDescending{it})

/**
 * 形象下方的单行状态提示，例如"分析用户请求 / 使用 Bash / 撰写回复"。
 * 文案由调用方按 phase / active_tool 推导，本组件只负责呈现，不猜业务状态。
 */
@Composable fun AvatarStatusPill(statusText:String,modifier:Modifier=Modifier,compact:Boolean=false){
 Surface(modifier.testTag("avatar-status-pill"),shape=RoundedCornerShape(16.dp),color=Card,shadowElevation=if(compact)2.dp else 4.dp){
  Row(Modifier.padding(horizontal=if(compact)10.dp else 14.dp,vertical=if(compact)4.dp else 6.dp),verticalAlignment=Alignment.CenterVertically){
   Icon(Icons.Outlined.Handyman,statusText,Modifier.size(14.dp),tint=Muted)
   Text(statusText,Modifier.padding(start=5.dp),fontSize=if(compact)Type.Micro else Type.Caption,color=Muted,maxLines=1,overflow=TextOverflow.Ellipsis)
  }
 }
}

/**
 * 按当前 phase / active_tool 推导形象状态文案。
 * 执行阶段保留真实工具名，分析阶段区分请求与工具结果；回复阶段不沿用过期工具名。
 */
fun avatarWorkStatus(phase:String,tool:String,hasToolResults:Boolean=false):String{
 val name=tool.trim().takeIf{it!="null"}.orEmpty()
 val t=name.lowercase()
 return when{
  phase=="offline"->"离线记录"
  phase=="unknown"->"状态待核实"
  phase in setOf("queued","pending","received")->"等待开始"
  phase=="sending"->"正在交给 Pi"
  phase in setOf("waiting","approval_required")->"等待你回应"
  phase in setOf("responding","replying","streaming")->"正在撰写回复"
  phase in setOf("executing","tool")&&name.isNotBlank()->when(t){
   "bash"->"正在使用 Bash · 执行命令"
   "read"->"正在使用 Read · 读取文件"
   "write"->"正在使用 Write · 写入文件"
   "edit"->"正在使用 Edit · 修改文件"
   "grep"->"正在使用 Grep · 检索内容"
   "glob"->"正在使用 Glob · 查找文件"
   else->"正在使用 $name"
  }
  phase=="thinking"&&hasToolResults->"正在分析工具结果"
  phase=="thinking"->"正在分析用户请求"
  phase in setOf("executing","tool")->"正在执行工具 · 等待名称"
  else->"状态待同步"
 }
}
