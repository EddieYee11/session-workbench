package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@Composable internal fun SettingsSection(icon:ImageVector,title:String,subtitle:String="",content:@Composable ColumnScope.()->Unit){
 Surface(Modifier.fillMaxWidth(),shape=RoundedCornerShape(24.dp),color=Card,border=BorderStroke(1.dp,Line)){
  Column(Modifier.padding(18.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
   Row(verticalAlignment=Alignment.CenterVertically){
    Box(Modifier.size(38.dp).background(ChipBg,CircleShape),contentAlignment=Alignment.Center){Icon(icon,null,Modifier.size(20.dp),tint=Ink)}
    Column(Modifier.weight(1f).padding(start=12.dp)){Text(title,fontSize=Type.Section,fontWeight=FontWeight.SemiBold);if(subtitle.isNotBlank())Text(subtitle,fontSize=Type.Caption,color=Muted)}
   }
   content()
  }
 }
}
@Composable internal fun SettingsLink(icon:ImageVector,title:String,subtitle:String="",click:()->Unit){
 Row(Modifier.fillMaxWidth().heightIn(min=52.dp).clickable(onClick=click).padding(vertical=8.dp),verticalAlignment=Alignment.CenterVertically){
  Icon(icon,null,Modifier.size(22.dp),tint=Muted)
  Column(Modifier.weight(1f).padding(horizontal=12.dp)){Text(title,fontSize=Type.BodySm,color=Ink);if(subtitle.isNotBlank())Text(subtitle,fontSize=Type.Caption,color=Muted)}
  Icon(Icons.Outlined.ChevronRight,null,Modifier.size(19.dp),tint=Faint)
 }
}
