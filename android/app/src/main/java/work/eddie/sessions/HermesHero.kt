package work.eddie.sessions

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val suggestions=listOf(
 Icons.Outlined.EventNote to "今天有什么安排？",
 Icons.Outlined.Edit to "帮我记一笔",
 Icons.Outlined.Notifications to "看看未读通知",
 Icons.Outlined.SmartToy to "Hermes 那边怎么样了",
)

/** 空状态：欢迎语 + 可点示例，点一下填入输入框 */
@OptIn(ExperimentalLayoutApi::class)
@Composable fun HermesHero(wide:Boolean,onSuggest:(String)->Unit){
 val haptics=rememberComHaptics()
 Column(Modifier.fillMaxWidth().padding(vertical=if(wide)56.dp else 32.dp),horizontalAlignment=Alignment.CenterHorizontally){
  Text("想从哪件事开始？",fontSize=24.sp,fontWeight=FontWeight.Medium,color=Ink)
  Text("聊聊今天，或一起推进手头的事。",Modifier.padding(top=12.dp),fontSize=14.sp,lineHeight=22.sp,color=Muted,textAlign=TextAlign.Center)
  FlowRow(Modifier.padding(top=20.dp).widthIn(max=560.dp),horizontalArrangement=Arrangement.spacedBy(8.dp,Alignment.CenterHorizontally),verticalArrangement=Arrangement.spacedBy(8.dp)){
   suggestions.forEach{(icon,label)->
    QuickChip(icon,label,true){haptics(HapticCue.Selection);onSuggest(label)}
   }
  }
 }
}
