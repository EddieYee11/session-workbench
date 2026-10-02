package work.eddie.sessions

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color

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
  R.drawable.com_icon_chat_v1->if(selected)Icons.Filled.ChatBubble else Icons.Outlined.ChatBubbleOutline
  R.drawable.com_icon_today_v1->Icons.Outlined.EventNote
  R.drawable.com_icon_activity_v1->Icons.Outlined.Lightbulb
  R.drawable.com_icon_work_v1->Icons.Outlined.CheckBox
  R.drawable.com_icon_settings_v1->Icons.Outlined.Widgets
  R.drawable.com_icon_finance_v1->Icons.Outlined.AccountBalanceWallet
  R.drawable.com_icon_menu_v1->Icons.Outlined.Menu
  R.drawable.com_icon_back_v1->Icons.Outlined.ArrowBack
  R.drawable.com_icon_chevron_v1->Icons.Outlined.ChevronRight
  R.drawable.com_icon_refresh_v1->Icons.Outlined.Refresh
  R.drawable.com_icon_mic_v1->Icons.Outlined.MicNone
  R.drawable.com_icon_send_v1->Icons.Outlined.ArrowUpward
  R.drawable.com_icon_stop_v1->Icons.Outlined.Stop
  else->Icons.Outlined.MoreHoriz
 }
 Icon(symbol,description,modifier,tint=tint.copy(alpha=tint.alpha*alpha))
}
