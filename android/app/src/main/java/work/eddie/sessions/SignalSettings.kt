package work.eddie.sessions

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.Manifest
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private fun signalTime(ms:Long)=if(ms<=0)"暂无" else SimpleDateFormat("M月d日 HH:mm",Locale.CHINA).format(Date(ms))

private fun openListenerSettings(context:Context){
 val general=Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
 if(Build.VERSION.SDK_INT>=30){
  val component=ComponentName(context,PersonalNotificationListener::class.java).flattenToString()
  val detail=Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
   .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,component)
  if(runCatching{context.startActivity(detail)}.isSuccess)return
 }
 runCatching{context.startActivity(general)}
}

@Composable fun SignalSettings(context:Context){
 var enabled by remember{mutableStateOf(SignalConfig.enabled(context))}
 var scope by remember{mutableStateOf(SignalConfig.scope(context))}
 var reminders by remember{mutableStateOf(SignalConfig.reminders(context))}
 var granted by remember{mutableStateOf(SignalConfig.accessGranted(context))}
 var stats by remember{mutableStateOf(runCatching{SignalQueue(context).stats()}.getOrNull())}
 var lastListen by remember{mutableLongStateOf(SignalConfig.lastListen(context))}
 var lastCaptured by remember{mutableLongStateOf(SignalConfig.lastCaptured(context))}
 var lastUpload by remember{mutableLongStateOf(SignalConfig.lastUpload(context))}
 var lastConnected by remember{mutableLongStateOf(SignalConfig.lastConnected(context))}
 var lastPoll by remember{mutableLongStateOf(SignalConfig.lastPoll(context))}
 var lastPollError by remember{mutableStateOf(SignalConfig.lastPollError(context))}
 var canNotify by remember{mutableStateOf(context.getSystemService(NotificationManager::class.java).areNotificationsEnabled()&&
  (Build.VERSION.SDK_INT<33||context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)==PackageManager.PERMISSION_GRANTED))}
 LaunchedEffect(Unit){while(true){
  granted=SignalConfig.accessGranted(context)
  stats=runCatching{SignalQueue(context).stats()}.getOrNull()
  lastListen=SignalConfig.lastListen(context)
  lastCaptured=SignalConfig.lastCaptured(context)
  lastUpload=SignalConfig.lastUpload(context)
  lastConnected=SignalConfig.lastConnected(context)
  lastPoll=SignalConfig.lastPoll(context)
  lastPollError=SignalConfig.lastPollError(context)
  canNotify=context.getSystemService(NotificationManager::class.java).areNotificationsEnabled()&&
   (Build.VERSION.SDK_INT<33||context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)==PackageManager.PERMISSION_GRANTED)
  delay(3000)
 }}
 HorizontalDivider(Modifier.padding(vertical=12.dp),color=Line)
 Text("个人 Agent · 手机通知",fontWeight=FontWeight.SemiBold)
 Text("由你开启后，所选应用的新通知标题和预览会在手机加密排队，发送到 Mac mini，由隔离的 Hermes / DeepSeek 分析，生成仅供你查看的记录与回复草稿。验证码、OTP 等敏感通知在手机端整条跳过。不会自动回复或发送消息。",Modifier.padding(top=5.dp,bottom=8.dp),fontSize=Type.Caption,lineHeight=18.sp,color=Muted)
 Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
  Text("采集通知",Modifier.weight(1f),fontSize=Type.BodySm,color=Ink)
  Switch(enabled,{value->
   SignalConfig.setEnabled(context,value);enabled=value
   stats=runCatching{SignalQueue(context).stats()}.getOrNull()
   if(value&&!SignalConfig.accessGranted(context))openListenerSettings(context)
  })
 }
 Text("系统监听授权：${if(granted)"已授权" else "未授权"}",fontSize=Type.Caption,color=if(granted)Muted else AmberText)
 TextButton(onClick={openListenerSettings(context)}){Text(if(granted)"查看或撤销系统授权"else"进入系统授权页面")}
 if(enabled){
  Text("采集范围",Modifier.padding(top=6.dp),fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=Ink)
  listOf("messages" to "微信和短信（默认）","all" to "所有应用").forEach{(value,label)->
   Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
    RadioButton(selected=scope==value,onClick={scope=value;SignalConfig.setScope(context,value)})
    Text(label,fontSize=Type.BodySm,color=Ink)
   }
  }
  if(scope=="all")Text("所有应用范围更广；系统状态、群摘要和识别为敏感的通知仍会跳过。",fontSize=Type.Caption,color=AmberText)
  Text("主动强度",Modifier.padding(top=10.dp),fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=Ink)
  val levels=listOf("quiet" to "安静","standard" to "标准","active" to "积极")
  var intensity by remember{mutableStateOf(SignalConfig.intensity(context))}
  Pill(levels.map{it.second},levels.indexOfFirst{it.first==intensity}.coerceAtLeast(0),click={i->
   val v=levels[i].first
   SignalConfig.setIntensity(context,v);intensity=v
   // 安静：不推送任何提醒，只在活动页看；标准/积极：重要事项推送提醒
   val wantReminders=v!="quiet"
   if(reminders!=wantReminders){reminders=wantReminders;SignalConfig.setReminders(context,wantReminders)}
  })
  Text("安静模式下重要事项也不推送提醒，只在活动页查看；标准/积极会推送重要事项提醒。",Modifier.padding(top=4.dp),fontSize=Type.Caption,color=Muted)
  Row(Modifier.fillMaxWidth().padding(top=8.dp),verticalAlignment=Alignment.CenterVertically){
   Text("重要结果静默提醒",Modifier.weight(1f),fontSize=Type.BodySm,color=Ink)
   Switch(reminders,{reminders=it;SignalConfig.setReminders(context,it)})
  }
  Text("仅提示有重要事项，锁屏不显示原通知或草稿；点开后在活动中查看。不会自动回复。",fontSize=Type.Caption,color=Muted)
  if(reminders&&!canNotify){
   Text("Com! 的系统通知权限未开启，重要结果只能在活动页查看。",Modifier.padding(top=5.dp),fontSize=Type.Caption,color=AmberText)
   TextButton(onClick={runCatching{context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE,context.packageName))}}){Text("打开 Com! 通知设置")}
  }
  val elapsed=if(lastPoll>0)((System.currentTimeMillis()-lastPoll)/60_000).coerceAtLeast(0) else 0
  Text("手机后台上次检查：${signalTime(lastPoll)}${if(lastPoll>0)" · 已过 ${elapsed} 分钟"else""}",Modifier.padding(top=7.dp),fontSize=Type.Caption,color=if(lastPoll>0&&elapsed>25)AmberText else Muted)
  Text("Android 约每 15 分钟尝试补传和检查，省电模式可能延后。${if(lastPollError.isNotBlank())"最近检查失败，稍后重试。"else""}",Modifier.padding(top=3.dp),fontSize=Type.Caption,color=Muted)
  Text("最后采集：${signalTime(lastCaptured)} · 最后上传：${signalTime(lastUpload)}",Modifier.padding(top=8.dp),fontSize=Type.Caption,color=Muted)
  Text("最后监听：${signalTime(lastListen)} · 服务连接：${signalTime(lastConnected)}",Modifier.padding(top=3.dp),fontSize=Type.Caption,color=Muted)
  Text("加密待传：${stats?.pending?.toString()?:"读取失败"} 条",Modifier.padding(top=3.dp),fontSize=Type.Caption,color=Muted)
  if((stats?.dropped?:0)>0)Text("队列已满时舍弃最早的 ${stats?.dropped} 条",Modifier.padding(top=3.dp),fontSize=Type.Caption,color=AmberText)
 }else Text("关闭后停止采集，并清空尚未上传的本地通知队列。",fontSize=Type.Caption,color=Muted)
}
