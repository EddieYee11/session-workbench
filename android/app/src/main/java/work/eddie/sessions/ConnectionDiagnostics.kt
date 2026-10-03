package work.eddie.sessions

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import org.json.JSONObject

@Composable fun ConnectionDiagnostics(vm:WorkbenchModel,back:()->Unit){
 var health by remember{mutableStateOf(JSONObject())}
 var error by remember{mutableStateOf("")}
 var refresh by remember{mutableIntStateOf(0)}
 LaunchedEffect(refresh){try{health=vm.store.request("/health");error=""}catch(e:Exception){error="服务暂不可达；请检查手机网络与服务地址"}}
 val details=listOf(
  "App ${BuildConfig.VERSION_NAME} / ${BuildConfig.VERSION_CODE}",
  "服务 ${health.optString("version","未读取")} / build ${health.optString("build_commit","未知")}",
  "API 契约 ${health.optInt("api_contract",0)}",
  "主 Pi 配置：${if(health.optJSONObject("features")?.optBoolean("pi_main")==true)"已选择" else "未核实"}",
  "主线连接：${if(vm.hermesStreaming)"实时连接中" else if(vm.hermesFresh)"已同步" else "未同步"}",
  "工作器权限配置：${health.optString("worker_operation_mode","未核实")}",
  "任务：${sourceReadState(vm.taskLedgerFresh,vm.workProposalsLoading,vm.taskLedger.has("items"),vm.taskLedger.optDouble("synced_at",0.0),vm.taskLedgerError).let{when(it.phase){ReadPhase.Synced->"已同步";ReadPhase.Cached->"缓存";ReadPhase.Loading->"读取中";ReadPhase.Failed->"读取失败";ReadPhase.NotLoaded->"未读取"}+" · "+it.timeLabel}}",
  "提醒来源：${if(vm.reminderFresh)"已读取" else "未同步"}",
  "主动观察：${if(vm.heartbeatNote.isBlank()&&vm.heartbeatState.length()>0)"已读取" else "未核实"}",
  "账本概览：${if(vm.personalFresh&&vm.personal.optJSONObject("finance")?.optBoolean("available")==true)"已读取" else "缓存或来源不可用"}",
  "通知巡检：${if(vm.signalsFresh)"已读取" else "未同步"}",
  error,vm.hermesError,vm.taskLedgerError,vm.personalError).filter{it.isNotBlank()}
 val clip=LocalClipboardManager.current
 Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp)){
  TextButton(onClick=back){Text("返回")}
  Text("连接诊断",fontSize=Type.SheetTitle,color=Ink)
  Text("权限配置与实际执行状态分别核对；手机日历在日历页查看。",Modifier.padding(vertical=12.dp),fontSize=Type.Caption,color=Muted)
  details.forEach{Text(it,Modifier.padding(vertical=7.dp),fontSize=Type.BodySm,color=Ink)}
  Row{
   TextButton(onClick={refresh++;vm.refreshHermesNow();vm.refreshPersonalNow();vm.refreshWorkProposalsNow();vm.refreshSignalsNow()}){Text("重新连接")}
   TextButton(onClick={clip.setText(AnnotatedString(details.joinToString("\n")))}){Text("复制诊断")}
  }
 }
}
