package work.eddie.sessions
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable fun HeartbeatSettings(vm:WorkbenchModel){
 LaunchedEffect(vm){if(vm.store.token.isNotBlank())vm.refreshHeartbeatNow()}
 var diagnostics by remember{mutableStateOf(false)}
 val cfg=vm.heartbeatState.optJSONObject("settings")
 Column(Modifier.fillMaxWidth().padding(vertical=12.dp)){
  Text("主动观察",fontSize=Type.BodySm,color=Ink)
  Text("默认影子模式：只记录观察，不通知、不创建任务。受限启用仅进入今天知情区或待批准建议。",fontSize=Type.Caption,color=Muted)
  Row{Text("暂停心跳",Modifier.weight(1f));Switch(cfg?.optBoolean("paused",false)?:false,{vm.setHeartbeat("paused",it)},enabled=cfg!=null)}
  Row{Text("受限启用",Modifier.weight(1f));Switch(!(cfg?.optBoolean("shadow",true)?:true),{vm.setHeartbeat("shadow",!it)},enabled=cfg!=null&&vm.heartbeatState.optBoolean("shadow_verified"))}
  if(!vm.heartbeatState.optBoolean("shadow_verified"))Text("完成两次有效影子观察后可手动启用",fontSize=Type.Micro,color=Muted)
  Text("每日最多24次 · 静默23:00–08:00 · 不发送系统推送",fontSize=Type.Micro,color=Muted)
  if(vm.heartbeatNote.isNotBlank())Text(vm.heartbeatNote,fontSize=Type.Caption,color=AmberText)
  TextButton(onClick={diagnostics=!diagnostics;vm.refreshHeartbeatNow()}){Text(if(diagnostics)"收起心跳诊断"else"心跳诊断")}
  if(diagnostics){
   Text(vm.heartbeatState.optString("checklist"),fontSize=Type.Micro,color=Muted)
   if(vm.heartbeatState.array("items").isEmpty())Text("还没有观察记录",fontSize=Type.Caption,color=Muted)
   vm.heartbeatState.array("items").take(10).forEach{row->
    val d=row.optJSONObject("decision")
    Text("${if(row.optBoolean("shadow"))"影子"else"受限"} · ${d?.optString("action")} · ${d?.optString("reason")}",fontSize=Type.Caption,color=Ink)
    Text("触发：${row.optString("trigger")}\n${row.optString("digest")}",fontSize=Type.Micro,color=Muted)
   }
  }
 }
}
@Composable fun HeartbeatAwareness(vm:WorkbenchModel){
 vm.heartbeatState.array("items").filter{it.optString("effect")=="awareness"}.take(3).forEach{r->
  val d=r.optJSONObject("decision")
  Text(d?.optString("text").orEmpty(),fontSize=Type.BodySm,color=Ink)
  Text("触发原因：${d?.optString("reason")}",fontSize=Type.Caption,color=Muted)
 }
}
