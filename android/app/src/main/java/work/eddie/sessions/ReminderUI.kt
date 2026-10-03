package work.eddie.sessions
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import org.json.JSONObject

@OptIn(ExperimentalLayoutApi::class)
@Composable fun ReminderCard(vm:WorkbenchModel,item:JSONObject){
 val pending=item.optString("status")=="pending"
 Column(Modifier.fillMaxWidth().padding(vertical=8.dp).testTag("reminder-${item.optString("id")}")){
  Text(item.optString("text"),fontSize=Type.BodySm,color=Ink)
  Text("${item.optString("due")} · ${when(item.optString("status")){"pending"->"待提醒";"done"->"已确认／已触发";"cancelled"->"已取消";else->"状态待核实"}}",fontSize=Type.Caption,color=Muted)
  if(pending)FlowRow{
   listOf("confirm" to "确认","snooze10" to "+10 分钟","snooze60" to "+1 小时","cancel" to "取消").forEach{(action,label)->
    TextButton(onClick={vm.reminderAction(item,action)},enabled=vm.reminderFresh&&vm.reminderBusy.isBlank()){Text(label,fontSize=Type.Caption)}
   }
  }
  if(vm.reminderNote.isNotBlank())Text(vm.reminderNote,fontSize=Type.Caption,color=AmberText)
 }
}
@Composable fun TodayReminderCards(vm:WorkbenchModel){
 val rows=vm.reminderState.array("items").filter{it.optString("status")=="pending"}.sortedBy{it.optString("due")}.take(5)
 if(rows.isEmpty())return
 Column{Text("提醒",fontSize=Type.BodySm,color=Ink);rows.forEach{ReminderCard(vm,it)}}
}
@Composable fun MessageReminderCards(vm:WorkbenchModel,message:JSONObject){
 val ids=message.array("tasks").map{it.optString("reminder_id")}.filter{it.isNotBlank()}.toSet()
 vm.reminderState.array("items").filter{it.optString("id") in ids}.forEach{ReminderCard(vm,it)}
}
