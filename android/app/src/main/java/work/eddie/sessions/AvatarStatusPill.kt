package work.eddie.sessions

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * 形象状态提示：叠在虚拟形象下方的小胶囊。
 * 第一行是名字，第二行是当前在干什么（带小图标），例如"拉取代码 / 开始修改 / 努力工作中"。
 * 文案由调用方按 phase / active_tool 推导，本组件只负责呈现，不猜业务状态。
 */
@Composable fun AvatarStatusPill(name:String,statusText:String,modifier:Modifier=Modifier){
 Surface(modifier,shape=RoundedCornerShape(20.dp),color=Card,shadowElevation=8.dp){
  Column(Modifier.padding(horizontal=16.dp,vertical=9.dp),horizontalAlignment=Alignment.CenterHorizontally){
   Text(name,fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=Ink)
   Row(Modifier.padding(top=3.dp),verticalAlignment=Alignment.CenterVertically){
    ComIcon(R.drawable.com_icon_work_v1,"工作中",Modifier.size(14.dp),tint=Muted)
    Text(statusText,Modifier.padding(start=5.dp),fontSize=Type.Caption,color=Muted)
   }
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
  "git" in t||"pull" in t||"fetch" in t||"clone" in t->"拉取代码"
  "edit" in t||"write" in t||"apply" in t||"patch" in t||"modify" in t->"开始修改"
  "search" in t||"web" in t||"browse" in t->"搜索资料"
  "calendar" in t->"查看日历"
  "propose" in t->"准备工作建议"
  phase=="thinking"->"努力思考中"
  phase in setOf("executing","tool")->"努力工作中"
  phase in setOf("responding","replying","streaming")->"正在回复"
  else->"工作中"
 }
}
