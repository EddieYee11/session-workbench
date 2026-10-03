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
 * 形象下方的单行状态提示，例如"拉取代码 / 开始修改 / 努力工作中"。
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
 * 优先给出具体动作（拉取代码/开始修改/搜索资料），退化为通用状态（努力工作中/正在回复）。
 */
fun avatarWorkStatus(phase:String,tool:String):String{
 val t=tool.lowercase()
 return when{
  phase=="offline"->"离线记录"
  phase=="unknown"->"状态待核实"
  phase in setOf("queued","pending","sending","received")->"等待开始"
  phase in setOf("waiting","approval_required")->"等待你回应"
  "git" in t||"pull" in t||"fetch" in t||"clone" in t->"拉取代码"
  "edit" in t||"write" in t||"apply" in t||"patch" in t||"modify" in t->"开始修改"
  "search" in t||"web" in t||"browse" in t->"搜索资料"
  "calendar" in t->"查看日历"
  "propose" in t->"准备工作建议"
  phase=="thinking"->"努力思考中"
  phase in setOf("executing","tool")->"努力工作中"
  phase in setOf("responding","replying","streaming")->"正在回复"
  else->"状态待同步"
 }
}
