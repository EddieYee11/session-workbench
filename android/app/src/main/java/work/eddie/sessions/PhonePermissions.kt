package work.eddie.sessions

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 手机上下文：通知 / 位置 / 通讯录 / 日历 / 麦克风。
 * 权限按需申请（用时才弹，每次讲清用途）；拿到后上下文直接可用。
 */
object PhoneContext{
 private fun prefs(context:Context)=context.getSharedPreferences("phone-context",Context.MODE_PRIVATE)

 fun locationGranted(context:Context)=context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)==PackageManager.PERMISSION_GRANTED
  ||context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)==PackageManager.PERMISSION_GRANTED
 fun contactsGranted(context:Context)=context.checkSelfPermission(Manifest.permission.READ_CONTACTS)==PackageManager.PERMISSION_GRANTED
 fun calendarGranted(context:Context)=context.checkSelfPermission(Manifest.permission.READ_CALENDAR)==PackageManager.PERMISSION_GRANTED
 fun micGranted(context:Context)=context.checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED
 fun listenerGranted(context:Context)=SignalConfig.accessGranted(context)

 /** 是否允许 Hermes 使用位置上下文（默认开，可关） */
 fun shareLocation(context:Context)=prefs(context).getBoolean("share_location",true)
 fun setShareLocation(context:Context,value:Boolean){prefs(context).edit().putBoolean("share_location",value).apply()}

 /** 最后一次成功获取的位置；"lat,lng · M月d日 HH:mm" 或空 */
 fun lastLocationText(context:Context):String{
  val lat=prefs(context).getFloat("last_lat",Float.NaN);val lng=prefs(context).getFloat("last_lng",Float.NaN)
  val at=prefs(context).getLong("last_loc_at",0)
  if(lat.isNaN()||lng.isNaN()||at<=0)return ""
  return "%.4f, %.4f · %s".format(lat,lng,SimpleDateFormat("M月d日 HH:mm",Locale.CHINA).format(Date(at)))
 }

 /** 主动刷新一次位置（需要已授权）；成功返回 true */
 fun refreshLocation(context:Context):Boolean{
  if(context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)!=PackageManager.PERMISSION_GRANTED
   &&context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)!=PackageManager.PERMISSION_GRANTED)return false
  return try{
   val lm=context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
   val loc=lm.getLastKnownLocation(LocationManager.GPS_PROVIDER)
    ?:lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
    ?:lm.getLastKnownLocation(LocationManager.PASSIVE_PROVIDER)
    ?:return false
   prefs(context).edit().putFloat("last_lat",loc.latitude.toFloat()).putFloat("last_lng",loc.longitude.toFloat())
    .putLong("last_loc_at",System.currentTimeMillis()).apply()
   true
  }catch(_:SecurityException){false} // Permission can be revoked after the check.
   catch(_:RuntimeException){false}
 }

 /** 通讯录联系人总数（用于展示“已可用”） */
 fun contactCount(context:Context):Int{
  if(!contactsGranted(context))return 0
  return runCatching{
   context.contentResolver.query(ContactsContract.Contacts.CONTENT_URI,arrayOf(ContactsContract.Contacts._ID),null,null,null)?.use{it.count}?:0
  }.getOrDefault(0)
 }

 /** 按号码查联系人名字；查不到返回 null */
 fun contactName(context:Context,phone:String):String?{
  if(!contactsGranted(context)||phone.isBlank())return null
  return runCatching{
   val uri=Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI,Uri.encode(phone))
   context.contentResolver.query(uri,arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),null,null,null)?.use{c->
    if(c.moveToFirst())c.getString(0) else null
   }
  }.getOrNull()
 }

 /** 手机本地日历今日事件数 */
 fun todayCalendarCount(context:Context):Int{
  if(!calendarGranted(context))return 0
  val zone=java.time.ZoneId.systemDefault()
  val today=java.time.LocalDate.now(zone)
  val result=readPhoneCalendar(context,today,days=1,zone=zone)
  return (result as? PhoneCalendarResult.Ready)?.let{phoneCalendarEventsOn(it.events,today,zone).size}?:0
 }
}

private fun openListenerSettings(context:Context){
 if(Build.VERSION.SDK_INT>=Build.VERSION_CODES.R){
  val detail=Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
   .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,ComponentName(context,PersonalNotificationListener::class.java).flattenToString())
  if(runCatching{context.startActivity(detail)}.isSuccess)return
 }
 runCatching{context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))}
}

@Composable private fun PermissionRow(
 icon:ImageVector,title:String,desc:String,granted:Boolean,
 rationale:String,
 onEnable:()->Unit,extra:@Composable ()->Unit={}
){
 Column(Modifier.fillMaxWidth().padding(vertical=10.dp)){
  Row(verticalAlignment=Alignment.CenterVertically){
   Icon(icon,null,Modifier.size(22.dp),tint=if(granted)Ink else Faint)
   Column(Modifier.weight(1f).padding(horizontal=12.dp)){
    Text(title,fontSize=Type.BodySm,fontWeight=FontWeight.Medium,color=Ink)
    Text(desc,fontSize=Type.Caption,color=Muted,lineHeight=16.sp)
   }
   if(granted)Text("已开启",fontSize=Type.Caption,color=PiGreen)
   else TextButton(onClick=onEnable){Text("开启",fontSize=Type.BodySm)}
  }
  var show by remember{mutableStateOf(false)}
  if(!granted){
   if(!show)TextButton(onClick={show=true},contentPadding=PaddingValues(0.dp)){Text("为什么需要这个权限？",fontSize=Type.Caption,color=Faint)}
   else Text(rationale,Modifier.padding(top=4.dp),fontSize=Type.Caption,lineHeight=18.sp,color=Muted)
  }
  extra()
 }
 HorizontalDivider(color=Line)
}

/** “更多”里的权限与上下文页：状态 + 按需申请 + 上下文直接可见 */
@Composable fun PermissionsSheetContent(){
 val context=androidx.compose.ui.platform.LocalContext.current
 var tick by remember{mutableIntStateOf(0)}
 val locLauncher=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){ok->if(ok)PhoneContext.refreshLocation(context);tick++}
 val conLauncher=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){tick++}
 val calLauncher=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){tick++}
 // 权限只在用户操作后才变：申请返回或从系统设置页回到本页（ON_RESUME）时刷新一次，不做轮询
 val lifecycle=androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
 DisposableEffect(lifecycle){
  val observer=androidx.lifecycle.LifecycleEventObserver{_,event->if(event==androidx.lifecycle.Lifecycle.Event.ON_RESUME)tick++}
  lifecycle.addObserver(observer)
  onDispose{lifecycle.removeObserver(observer)}
 }
 val locGranted=remember(tick){PhoneContext.locationGranted(context)}
 val conGranted=remember(tick){PhoneContext.contactsGranted(context)}
 val calGranted=remember(tick){PhoneContext.calendarGranted(context)}
 val conCount=remember(tick){PhoneContext.contactCount(context)}
 var calCount by remember{mutableStateOf<Int?>(null)}
 LaunchedEffect(tick,calGranted){
  calCount=if(calGranted)kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO){PhoneContext.todayCalendarCount(context)}else null
 }
 Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal=22.dp).padding(bottom=28.dp)){
  Text("权限与上下文",fontSize=22.sp,fontWeight=FontWeight.SemiBold,color=Ink)
  Text("上下文直接来自手机：通知、日历、位置、通讯录。权限只在你要用它时才申请，随时可关。",Modifier.padding(top=4.dp,bottom=8.dp),fontSize=Type.Caption,lineHeight=18.sp,color=Muted)

  PermissionRow(Icons.Outlined.Notifications,"手机通知","新通知经 Hermes 分析成摘要与草稿",remember(tick){PhoneContext.listenerGranted(context)},
   "开启后，所选应用的新通知会在手机加密排队、发到 Mac mini 分析。验证码等敏感通知整条跳过，不会自动回复。",{openListenerSettings(context)})

  var share by remember{mutableStateOf(PhoneContext.shareLocation(context))}
  val locText=remember(tick){PhoneContext.lastLocationText(context)}
  PermissionRow(Icons.Outlined.Place,"位置信息","Hermes 知道你在哪：迟到提醒、附近推荐",locGranted,
   "开启后，Hermes 可以结合你的实时位置和日程地点，在你要迟到时提醒你出门。位置只在你要用时获取。",{locLauncher.launch(Manifest.permission.ACCESS_FINE_LOCATION)}){
   if(locGranted){
    Row(Modifier.fillMaxWidth().padding(top=6.dp),verticalAlignment=Alignment.CenterVertically){
     Text("让 Hermes 使用我的位置",Modifier.weight(1f),fontSize=Type.BodySm,color=Ink)
     Switch(share,{share=it;PhoneContext.setShareLocation(context,it)})
    }
    Row(verticalAlignment=Alignment.CenterVertically){
     Text(if(locText.isBlank())"尚未获取到位置" else "当前位置 $locText",Modifier.weight(1f),fontSize=Type.Caption,color=Muted)
     TextButton(onClick={PhoneContext.refreshLocation(context);tick++}){Text("刷新",fontSize=Type.Caption)}
    }
   }
  }

  PermissionRow(Icons.Outlined.Contacts,"通讯录","来电和短信显示名字而不是号码",conGranted,
   "开启后，通知里的陌生号码会自动匹配成联系人名字。通讯录只在手机本地解析。",{conLauncher.launch(Manifest.permission.READ_CONTACTS)}){
   if(conGranted)Text("已加载 $conCount 个联系人",Modifier.padding(top=4.dp),fontSize=Type.Caption,color=Muted)
  }

  PermissionRow(Icons.Outlined.EventNote,"手机日历","本地日程也出现在今天页",calGranted,
   "开启后，今天页直接读取手机可见日历中的日程。日历只在手机本地读取。",{calLauncher.launch(Manifest.permission.READ_CALENDAR)}){
   if(calGranted)Text(calCount?.let{"手机日历今天 $it 条"}?:"正在读取手机日历…",Modifier.padding(top=4.dp),fontSize=Type.Caption,color=Muted)
  }

  PermissionRow(Icons.Outlined.Mic,"麦克风","快捷语音和 Hermes 语音输入",remember(tick){PhoneContext.micGranted(context)},
   "按住电源键和 Hermes 说一句，或在对话里直接语音输入。",{})
 }
}
