package work.eddie.sessions

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/** One monochrome symbol family across navigation, cards and conversation controls. */
@Composable fun ComIcon(
 resource:Int,
 description:String?,
 modifier:Modifier=Modifier,
 alpha:Float=1f,
 tint:Color=Ink,
 selected:Boolean=false
){
 val symbol=when(resource){
  R.drawable.com_icon_chat_v1->ReferenceIcons.Chat
  R.drawable.com_icon_today_v1->ReferenceIcons.Calendar
  R.drawable.com_icon_activity_v1->Icons.Outlined.Lightbulb
  R.drawable.com_icon_work_v1->ReferenceIcons.Work
  R.drawable.com_icon_settings_v1->ReferenceIcons.Sliders
  R.drawable.com_icon_finance_v1->Icons.Outlined.AccountBalanceWallet
  R.drawable.com_icon_menu_v1->Icons.Outlined.Menu
  R.drawable.com_icon_back_v1->Icons.Outlined.ArrowBack
  R.drawable.com_icon_chevron_v1->Icons.Outlined.ChevronRight
  R.drawable.com_icon_refresh_v1->Icons.Outlined.Refresh
  R.drawable.com_icon_mic_v1->ReferenceIcons.Mic
  R.drawable.com_icon_send_v1->Icons.Outlined.ArrowUpward
  R.drawable.com_icon_stop_v1->Icons.Outlined.Stop
  else->Icons.Outlined.MoreHoriz
 }
 Icon(symbol,description,modifier,tint=tint.copy(alpha=tint.alpha*alpha))
}

/** Rounded outline geometry matching the supplied reference, using Com's own palette. */
internal object ReferenceIcons {
 private fun outline(name:String,draw:PathBuilder.()->Unit):ImageVector =
  ImageVector.Builder(name,24.dp,24.dp,24f,24f).apply {
   path(fill=null,stroke=SolidColor(Color.Black),strokeLineWidth=1.65f,strokeLineCap=StrokeCap.Round,strokeLineJoin=StrokeJoin.Round){draw()}
  }.build()
 val Chat=outline("ComReferenceChat"){
  moveTo(20.5f,11.3f);curveTo(20.5f,6.9f,16.7f,3.9f,12f,3.9f);curveTo(7.3f,3.9f,3.5f,6.9f,3.5f,11.3f)
  curveTo(3.5f,13.1f,4.1f,14.7f,5.4f,16f);lineTo(4.2f,20f);lineTo(8.2f,18.6f)
  curveTo(9.3f,19f,10.6f,19.2f,12f,19.2f);curveTo(16.7f,19.2f,20.5f,15.6f,20.5f,11.3f);close()
  moveTo(8f,11.4f);lineTo(8.01f,11.4f);moveTo(12f,11.4f);lineTo(12.01f,11.4f);moveTo(16f,11.4f);lineTo(16.01f,11.4f)
 }
 val Calendar=outline("ComReferenceCalendar"){
  moveTo(6.3f,4.6f);lineTo(17.7f,4.6f);quadTo(20f,4.6f,20f,7f);lineTo(20f,18.6f);quadTo(20f,21f,17.7f,21f)
  lineTo(6.3f,21f);quadTo(4f,21f,4f,18.6f);lineTo(4f,7f);quadTo(4f,4.6f,6.3f,4.6f);close()
  moveTo(8f,2.8f);lineTo(8f,6.5f);moveTo(16f,2.8f);lineTo(16f,6.5f);moveTo(4f,9.2f);lineTo(20f,9.2f)
  moveTo(8f,13f);lineTo(12f,13f);lineTo(12f,17f);lineTo(8f,17f);close()
 }
 val Tasks=outline("ComReferenceTasks"){
  for(y in listOf(4f,10f,16f)){
   moveTo(4f,y);lineTo(7f,y);quadTo(7.5f,y,7.5f,y+.5f);lineTo(7.5f,y+3f);quadTo(7.5f,y+3.5f,7f,y+3.5f)
   lineTo(4f,y+3.5f);quadTo(3.5f,y+3.5f,3.5f,y+3f);lineTo(3.5f,y+.5f);quadTo(3.5f,y,4f,y);close()
   moveTo(11f,y+.7f);lineTo(20.5f,y+.7f);moveTo(11f,y+2.8f);lineTo(16.5f,y+2.8f)
  }
 }
 val Memory=outline("ComReferenceMemory"){
  moveTo(9f,5.5f);curveTo(9.5f,10f,10.5f,11.5f,15f,12f);curveTo(10.5f,12.5f,9.5f,14f,9f,18.5f)
  curveTo(8.5f,14f,7.5f,12.5f,3f,12f);curveTo(7.5f,11.5f,8.5f,10f,9f,5.5f);close()
  moveTo(18f,2.8f);quadTo(18.2f,5.5f,21f,5.8f);quadTo(18.2f,6.1f,18f,8.8f);quadTo(17.8f,6.1f,15f,5.8f);quadTo(17.8f,5.5f,18f,2.8f);close()
  moveTo(18f,15f);quadTo(18.2f,17.5f,20.7f,17.8f);quadTo(18.2f,18.1f,18f,20.6f);quadTo(17.8f,18.1f,15.3f,17.8f);quadTo(17.8f,17.5f,18f,15f);close()
 }
 val Sliders=outline("ComReferenceSliders"){
  moveTo(4f,7f);lineTo(6.5f,7f);moveTo(11.5f,7f);lineTo(20f,7f)
  moveTo(11.5f,7f);arcToRelative(2.5f,2.5f,0f,true,true,-5f,0f);arcToRelative(2.5f,2.5f,0f,true,true,5f,0f)
  moveTo(4f,17f);lineTo(12.5f,17f);moveTo(17.5f,17f);lineTo(20f,17f)
  moveTo(17.5f,17f);arcToRelative(2.5f,2.5f,0f,true,true,-5f,0f);arcToRelative(2.5f,2.5f,0f,true,true,5f,0f)
 }
 val Plus=outline("ComReferencePlus"){moveTo(12f,5f);lineTo(12f,19f);moveTo(5f,12f);lineTo(19f,12f)}
 val Mic=outline("ComReferenceMic"){
  moveTo(9f,5f);curveTo(9f,1.5f,15f,1.5f,15f,5f);lineTo(15f,10.5f);curveTo(15f,14f,9f,14f,9f,10.5f);close()
  moveTo(6f,10f);lineTo(6f,11f);curveTo(6f,19f,18f,19f,18f,11f);lineTo(18f,10f)
  moveTo(12f,17f);lineTo(12f,21f)
 }
 val Work=outline("ComReferenceWork"){
  moveTo(5f,4f);lineTo(19f,4f);quadTo(20f,4f,20f,5f);lineTo(20f,19f);quadTo(20f,20f,19f,20f)
  lineTo(5f,20f);quadTo(4f,20f,4f,19f);lineTo(4f,5f);quadTo(4f,4f,5f,4f);close()
  moveTo(8f,12f);lineTo(11f,15f);lineTo(17f,9f)
 }
}
