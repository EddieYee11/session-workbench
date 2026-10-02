package work.eddie.sessions

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable fun HermesHero(wide:Boolean){
 Column(Modifier.fillMaxWidth().padding(vertical=if(wide)56.dp else 32.dp),horizontalAlignment=Alignment.CenterHorizontally){
  Text("想从哪件事开始？",fontSize=24.sp,fontWeight=FontWeight.Medium,color=Ink)
  Text("聊聊今天，或一起推进手头的事。",Modifier.padding(top=12.dp),fontSize=14.sp,lineHeight=22.sp,color=Muted,textAlign=TextAlign.Center)
 }
}
