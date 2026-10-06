package work.eddie.sessions

import android.Manifest
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowBack
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Calendar instances stay on this phone; they are never included in gateway requests. */
data class PhoneCalendarEvent(
 val id:Long,
 val title:String,
 val begin:Long,
 val end:Long,
 val allDay:Boolean=false,
 val location:String="",
 val calendarName:String="",
 val visible:Boolean=true,
 val status:Int=0,
 val attendeeStatus:Int=0,
){
 val instanceKey:Pair<Long,Long> get()=id to begin
}

data class PhoneCalendarWindow(val begin:Long,val end:Long,val queryBegin:Long,val queryEnd:Long)

/** Civil days can be 23 or 25 hours. All-day timestamps instead encode UTC dates. */
fun phoneCalendarWindow(date:LocalDate,days:Long=1,zone:ZoneId=ZoneId.systemDefault()):PhoneCalendarWindow{
 require(days>0)
 val last=date.plusDays(days)
 val begin=date.atStartOfDay(zone).toInstant().toEpochMilli()
 val end=last.atStartOfDay(zone).toInstant().toEpochMilli()
 val utcBegin=date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
 val utcEnd=last.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
 return PhoneCalendarWindow(begin,end,minOf(begin,utcBegin),maxOf(end,utcEnd))
}

fun phoneCalendarEventsOn(events:List<PhoneCalendarEvent>,date:LocalDate,zone:ZoneId=ZoneId.systemDefault()):List<PhoneCalendarEvent>{
 val day=phoneCalendarWindow(date,zone=zone)
 return events.asSequence()
  // Android STATUS_CANCELED and ATTENDEE_STATUS_DECLINED are both 2.
  .filter{it.visible&&it.status!=2&&it.attendeeStatus!=2}
  .filter{event->
   if(event.allDay){
    val first=Instant.ofEpochMilli(event.begin).atZone(ZoneOffset.UTC).toLocalDate()
    val rawLast=Instant.ofEpochMilli(event.end).atZone(ZoneOffset.UTC).toLocalDate()
    val last=if(rawLast>first)rawLast else first.plusDays(1)
    date>=first&&date<last
   }else if(event.end<=event.begin){
    event.begin>=day.begin&&event.begin<day.end
   }else event.begin<day.end&&event.end>day.begin
  }
  .distinctBy{it.instanceKey}
  .sortedWith(compareBy<PhoneCalendarEvent>{!it.allDay}.thenBy{it.begin}.thenBy{it.id})
  .toList()
}

fun phoneCalendarEventTime(event:PhoneCalendarEvent,date:LocalDate,zone:ZoneId=ZoneId.systemDefault()):String=when{
 event.allDay->"全天"
 Instant.ofEpochMilli(event.begin).atZone(zone).toLocalDate()<date->"跨日"
 else->Instant.ofEpochMilli(event.begin).atZone(zone).format(DateTimeFormatter.ofPattern("HH:mm"))
}

sealed interface PhoneCalendarResult{
 data object Loading:PhoneCalendarResult
 data object NoPermission:PhoneCalendarResult
 data class Ready(val events:List<PhoneCalendarEvent>):PhoneCalendarResult
 data class Failed(val message:String):PhoneCalendarResult
}

/** Blocking provider query; callers run this on Dispatchers.IO. Instances expands recurrences. */
fun readPhoneCalendar(context:Context,date:LocalDate,days:Long=7,zone:ZoneId=ZoneId.systemDefault()):PhoneCalendarResult{
 if(context.checkSelfPermission(Manifest.permission.READ_CALENDAR)!=PackageManager.PERMISSION_GRANTED)return PhoneCalendarResult.NoPermission
 val window=phoneCalendarWindow(date,days,zone)
 val projection=arrayOf(
  CalendarContract.Instances.EVENT_ID,CalendarContract.Instances.TITLE,
  CalendarContract.Instances.BEGIN,CalendarContract.Instances.END,
  CalendarContract.Instances.ALL_DAY,CalendarContract.Instances.EVENT_LOCATION,
  CalendarContract.Instances.CALENDAR_DISPLAY_NAME,CalendarContract.Instances.VISIBLE,
  CalendarContract.Instances.STATUS,CalendarContract.Instances.SELF_ATTENDEE_STATUS,
 )
 return try{
  val cursor=CalendarContract.Instances.query(context.contentResolver,projection,window.queryBegin,window.queryEnd)
   ?:return PhoneCalendarResult.Failed("手机日历暂时无法读取")
  val events=cursor.use{c->buildList{
   while(c.moveToNext())add(PhoneCalendarEvent(
    id=c.getLong(0),title=c.getString(1)?.ifBlank{"（无标题）"}?:"（无标题）",
    begin=c.getLong(2),end=c.getLong(3),allDay=c.getInt(4)!=0,
    location=c.getString(5).orEmpty(),calendarName=c.getString(6).orEmpty(),
    visible=c.getInt(7)!=0,status=if(c.isNull(8))0 else c.getInt(8),
    attendeeStatus=if(c.isNull(9))0 else c.getInt(9),
   ))
  }}
  PhoneCalendarResult.Ready(events.distinctBy{it.instanceKey})
 }catch(_:SecurityException){
  PhoneCalendarResult.NoPermission
 }catch(_:RuntimeException){
  PhoneCalendarResult.Failed("手机日历读取失败，请重试")
 }
}

private class PhoneCalendarUiState{
 var today by mutableStateOf(LocalDate.now())
 var zone by mutableStateOf(ZoneId.systemDefault())
 var result by mutableStateOf<PhoneCalendarResult>(PhoneCalendarResult.Loading)
 var revision by mutableIntStateOf(0)
 fun refresh(){zone=ZoneId.systemDefault();today=LocalDate.now(zone);revision++}
}

@Composable private fun rememberPhoneCalendar():PhoneCalendarUiState{
 val context=LocalContext.current
 val lifecycle=LocalLifecycleOwner.current.lifecycle
 val state=remember{PhoneCalendarUiState()}
 val granted=context.checkSelfPermission(Manifest.permission.READ_CALENDAR)==PackageManager.PERMISSION_GRANTED
 DisposableEffect(context,lifecycle){
  val observer=LifecycleEventObserver{_,event->if(event==Lifecycle.Event.ON_RESUME)state.refresh()}
  lifecycle.addObserver(observer)
  val receiver=object:BroadcastReceiver(){override fun onReceive(c:Context?,intent:Intent?){state.refresh()}}
  val filter=IntentFilter().apply{
   addAction(Intent.ACTION_DATE_CHANGED);addAction(Intent.ACTION_TIME_CHANGED);addAction(Intent.ACTION_TIMEZONE_CHANGED)
  }
  if(Build.VERSION.SDK_INT>=33)context.registerReceiver(receiver,filter,Context.RECEIVER_NOT_EXPORTED)
  else context.registerReceiver(receiver,filter)
  onDispose{lifecycle.removeObserver(observer);context.unregisterReceiver(receiver)}
 }
 DisposableEffect(context,granted){
  val observer=object:ContentObserver(Handler(Looper.getMainLooper())){
   override fun onChange(selfChange:Boolean){state.refresh()}
  }
  val registered=granted&&runCatching{
   context.contentResolver.registerContentObserver(CalendarContract.CONTENT_URI,true,observer)
  }.isSuccess
  onDispose{if(registered)context.contentResolver.unregisterContentObserver(observer)}
 }
 LaunchedEffect(state.revision){
  val queryDate=state.today
  val queryZone=state.zone
  state.result=PhoneCalendarResult.Loading
  state.result=withContext(Dispatchers.IO){readPhoneCalendar(context,queryDate,zone=queryZone)}
 }
 LaunchedEffect(state.today,state.zone,state.revision){
  val next=state.today.plusDays(1).atStartOfDay(state.zone).toInstant().toEpochMilli()
  delay((next-System.currentTimeMillis()).coerceAtLeast(100L)+100L)
  state.refresh()
 }
 return state
}

private val CalendarInk=Color(0xFF0A84FF)
private val CalendarMuted=Color(0xFF97979D)
private val CalendarFaint=Color(0xFF97979D)
private val CalendarLine=Color(0x14FFFFFF)
private val CalendarEmber=Color(0xFF0A84FF)

/** Com2's calendar rows: 48 dp time column, fine vertical marker, title and location. */
@Composable fun PhoneCalendarCard(compact:Boolean=false){
 val context=LocalContext.current
 val state=rememberPhoneCalendar()
 var selectedDay by remember{mutableStateOf(state.today)}
 var lastToday by remember{mutableStateOf(state.today)}
 var expanded by remember(selectedDay){mutableStateOf(false)}
 val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){state.refresh()}
 LaunchedEffect(state.today){
  if(selectedDay==lastToday||selectedDay<state.today||selectedDay>=state.today.plusDays(7))selectedDay=state.today
  lastToday=state.today
 }
 val allEvents=(state.result as? PhoneCalendarResult.Ready)?.events.orEmpty()
 val events=remember(allEvents,selectedDay,state.zone){phoneCalendarEventsOn(allEvents,selectedDay,state.zone)}
 var askedPermission by remember{mutableStateOf(false)}
 val allow:()->Unit={askedPermission=true;permission.launch(Manifest.permission.READ_CALENDAR)}
 Column(Modifier.fillMaxWidth()){
  Row(Modifier.fillMaxWidth().padding(bottom=8.dp),verticalAlignment=Alignment.CenterVertically){
   Text("日历",Modifier.weight(1f),fontSize=11.sp,fontWeight=FontWeight.Bold,color=CalendarFaint,letterSpacing=1.4.sp)
   Text(if(selectedDay==state.today)"今天" else selectedDay.format(DateTimeFormatter.ofPattern("M月d日")),fontSize=11.sp,color=CalendarMuted)
   IconButton(onClick={state.refresh()},modifier=Modifier.size(32.dp)){
    Icon(Icons.Outlined.Refresh,"刷新手机日历",Modifier.size(17.dp),tint=CalendarMuted)
   }
  }
  if(state.result!=PhoneCalendarResult.NoPermission){
   Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(bottom=10.dp),horizontalArrangement=Arrangement.spacedBy(5.dp)){
    repeat(7){offset->
     val day=state.today.plusDays(offset.toLong())
     val selected=selectedDay==day
     val hasEvents=phoneCalendarEventsOn(allEvents,day,state.zone).isNotEmpty()
     Column(Modifier.width(44.dp).height(70.dp).clip(RoundedCornerShape(14.dp))
      .background(if(selected)CalendarInk else Card)
      .selectable(selected=selected,role=Role.Tab,onClick={selectedDay=day}),
      horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.Center){
      Text(if(offset==0)"今天"else day.format(DateTimeFormatter.ofPattern("E",Locale.CHINA)),fontSize=10.sp,color=if(selected)Color.White.copy(alpha=.75f)else CalendarMuted)
      Text(day.dayOfMonth.toString(),Modifier.padding(vertical=3.dp),fontSize=17.sp,fontWeight=FontWeight.SemiBold,color=if(selected)Color.White else Ink)
      Box(Modifier.size(3.dp).background(if(hasEvents)if(selected)Color.White else CalendarEmber else Color.Transparent,CircleShape))
     }
    }
   }
  }
  Surface(Modifier.fillMaxWidth(),shape=RoundedCornerShape(20.dp),color=Color.White,border=BorderStroke(1.dp,CalendarLine),shadowElevation=0.dp){
   when(val result=state.result){
    PhoneCalendarResult.NoPermission->Column{
     Row(Modifier.fillMaxWidth().clickable(onClick=allow).padding(16.dp),verticalAlignment=Alignment.CenterVertically){
      Icon(Icons.Outlined.CalendarMonth,null,Modifier.size(22.dp),tint=CalendarMuted)
      Column(Modifier.weight(1f).padding(start=12.dp)){
       Text("读取手机日历",fontSize=14.sp,fontWeight=FontWeight.Medium,color=CalendarInk)
       Text("授权后显示今日日程，仅在手机读取",fontSize=12.sp,color=CalendarMuted,lineHeight=18.sp)
      }
      Icon(Icons.Outlined.ChevronRight,null,tint=CalendarFaint)
     }
     if(askedPermission)TextButton(onClick={
      context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,android.net.Uri.parse("package:${context.packageName}")))
     },modifier=Modifier.padding(start=8.dp,bottom=4.dp)){Text("在系统设置中开启日历权限",fontSize=12.sp,color=CalendarMuted)}
    }
    PhoneCalendarResult.Loading->Row(Modifier.padding(20.dp),verticalAlignment=Alignment.CenterVertically){
     CircularProgressIndicator(Modifier.size(15.dp),color=CalendarMuted,strokeWidth=1.5.dp)
     Text("读取手机日历…",Modifier.padding(start=10.dp),fontSize=13.sp,color=CalendarMuted)
    }
    is PhoneCalendarResult.Failed->Column(Modifier.padding(horizontal=16.dp,vertical=10.dp)){
     Text(result.message,fontSize=13.sp,color=CalendarMuted)
     TextButton(onClick={state.refresh()},contentPadding=PaddingValues(0.dp)){Text("重新读取",fontSize=12.sp,color=CalendarInk)}
    }
    is PhoneCalendarResult.Ready->if(events.isEmpty()){
     Text(if(selectedDay==state.today)"今天没有安排，好好休息。"else"这一天没有安排。",Modifier.padding(16.dp),fontSize=14.sp,color=CalendarMuted)
    }else Column(Modifier.padding(horizontal=4.dp,vertical=6.dp)){
     (if(compact&&!expanded)events.take(3)else events).forEach{event->
      key(event.instanceKey){PhoneCalendarEventRow(event,selectedDay,state.zone)}
     }
     if(compact&&events.size>3)TextButton(onClick={expanded=!expanded},modifier=Modifier.fillMaxWidth()){
      Text(if(expanded)"收起日程"else"查看其余 ${events.size-3} 个日程",fontSize=12.sp,color=CalendarMuted)
     }
    }
   }
  }
  Text("手机日历 · 本地读取",Modifier.padding(top=7.dp,start=4.dp),fontSize=10.sp,color=CalendarFaint)
 }
}

/** 「今天」的时间轴骨架：只显示今天，全天事项折叠为一行；完整 7 天视图在日历页。 */
@Composable fun TodayTimelineCard(openCalendar:()->Unit){
 val state=rememberPhoneCalendar()
 val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){state.refresh()}
 var askedPermission by remember{mutableStateOf(false)}
 val allow:()->Unit={askedPermission=true;permission.launch(Manifest.permission.READ_CALENDAR)}
 val allEvents=(state.result as? PhoneCalendarResult.Ready)?.events.orEmpty()
 val events=remember(allEvents,state.today,state.zone){phoneCalendarEventsOn(allEvents,state.today,state.zone)}
 val timed=events.filter{!it.allDay}
 val allDay=events.filter{it.allDay}
 Surface(onClick=openCalendar,modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(20.dp),color=Color.White,border=BorderStroke(1.dp,CalendarLine),shadowElevation=0.dp){
  Column(Modifier.padding(horizontal=18.dp,vertical=16.dp)){
   Row(verticalAlignment=Alignment.CenterVertically){
    Text("今天",Modifier.weight(1f),fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=CalendarInk)
    Text("打开日历",fontSize=Type.Caption,color=CalendarMuted)
    Icon(Icons.Outlined.ChevronRight,null,Modifier.size(18.dp),tint=CalendarFaint)
   }
   when(val result=state.result){
    PhoneCalendarResult.NoPermission->Row(Modifier.fillMaxWidth().padding(top=10.dp).clickable(onClick=allow),verticalAlignment=Alignment.CenterVertically){
     Text(if(askedPermission)"未授权，到系统设置开启日历" else "读取手机日历",Modifier.weight(1f),fontSize=Type.BodySm,color=CalendarInk)
     Text("授权",fontSize=Type.Caption,color=CalendarEmber)
    }
    PhoneCalendarResult.Loading->Text("读取手机日历…",Modifier.padding(top=10.dp),fontSize=Type.BodySm,color=CalendarMuted)
    is PhoneCalendarResult.Failed->Text(result.message,Modifier.padding(top=10.dp),fontSize=Type.BodySm,color=CalendarMuted)
    is PhoneCalendarResult.Ready->Column(Modifier.padding(top=4.dp)){
     if(timed.isEmpty()&&allDay.isEmpty())Text("今天没有安排，好好休息。",Modifier.padding(top=6.dp),fontSize=Type.BodySm,color=CalendarMuted)
     timed.take(3).forEach{event->key(event.instanceKey){PhoneCalendarEventRow(event,state.today,state.zone)}}
     if(timed.size>3)Text("还有 ${timed.size-3} 项日程",Modifier.padding(top=6.dp),fontSize=Type.Caption,color=CalendarMuted)
     if(allDay.isNotEmpty())Text("全天 · ${allDay.joinToString("、"){it.title}}",Modifier.padding(top=8.dp),fontSize=Type.Caption,color=CalendarMuted,maxLines=1,overflow=TextOverflow.Ellipsis)
    }
   }
  }
 }
}

@Composable private fun PhoneCalendarEventRow(event:PhoneCalendarEvent,date:LocalDate,zone:ZoneId){
 val context=LocalContext.current
 Row(Modifier.fillMaxWidth().clickable(role=Role.Button){
  val uri=ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI,event.id)
  val intent=Intent(Intent.ACTION_VIEW,uri)
   .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME,event.begin)
   .putExtra(CalendarContract.EXTRA_EVENT_END_TIME,event.end)
  runCatching{context.startActivity(intent)}.onFailure{
   Toast.makeText(context,"未找到可打开此日程的日历应用",Toast.LENGTH_SHORT).show()
  }
 }.padding(horizontal=12.dp,vertical=10.dp),verticalAlignment=Alignment.CenterVertically){
  Text(phoneCalendarEventTime(event,date,zone),Modifier.width(48.dp),fontSize=12.sp,color=CalendarMuted,fontWeight=FontWeight.Medium)
  Box(Modifier.width(3.dp).height(34.dp).background(CalendarEmber,RoundedCornerShape(2.dp)))
  Column(Modifier.weight(1f).padding(start=12.dp)){
   Text(event.title,fontSize=14.sp,fontWeight=FontWeight.Medium,color=CalendarInk,maxLines=1,overflow=TextOverflow.Ellipsis)
   val detail=event.location.ifBlank{event.calendarName}
   if(detail.isNotBlank())Text(detail,fontSize=12.sp,color=CalendarMuted,maxLines=1,overflow=TextOverflow.Ellipsis)
  }
 }
}

@Composable fun PhoneCalendarPage(back:()->Unit){
 Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal=20.dp,vertical=12.dp),horizontalAlignment=Alignment.CenterHorizontally){
  Column(Modifier.widthIn(max=820.dp).fillMaxWidth()){
   Row(Modifier.padding(bottom=16.dp),verticalAlignment=Alignment.CenterVertically){
    IconButton(onClick=back){Icon(Icons.Outlined.ArrowBack,"返回",tint=CalendarInk)}
    Text("手机日历",fontSize=23.sp,fontWeight=FontWeight.SemiBold,color=CalendarInk)
   }
   PhoneCalendarCard()
  }
 }
}
