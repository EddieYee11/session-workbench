package work.eddie.sessions

import android.Manifest
import android.app.*
import android.app.usage.UsageStatsManager
import android.content.*
import android.content.pm.PackageManager
import android.database.Cursor
import android.hardware.camera2.CameraManager
import android.location.LocationManager
import android.media.AudioManager
import android.net.Uri
import android.os.*
import android.provider.*
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.*
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.time.TimeRangeFilter
import org.json.*
import java.time.Instant
import java.time.Duration

class PhoneNodeTools(val context:Context){
 private val cr=context.contentResolver
 private fun granted(permission:String)=context.checkSelfPermission(permission)==PackageManager.PERMISSION_GRANTED
 private fun usageGranted():Boolean{
  val ops=context.getSystemService(AppOpsManager::class.java)
  return ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS,android.os.Process.myUid(),context.packageName)==AppOpsManager.MODE_ALLOWED
 }
 suspend fun capabilities():JSONArray{
  val hc=HealthConnectClient.getSdkStatus(context)==HealthConnectClient.SDK_AVAILABLE
  val healthPermissions=if(hc)runCatching{HealthConnectClient.getOrCreate(context).permissionController.getGrantedPermissions()}.getOrDefault(emptySet())else emptySet()
  val caps=JSONArray()
  fun add(tool:String,permission:Boolean,available:Boolean=true){caps.put(JSONObject().put("tool",tool).put("permission",permission).put("available",available))}
  add("calendar.list",granted(Manifest.permission.READ_CALENDAR));add("calendar.create",granted(Manifest.permission.WRITE_CALENDAR)&&granted(Manifest.permission.READ_CALENDAR));add("calendar.update",granted(Manifest.permission.WRITE_CALENDAR)&&granted(Manifest.permission.READ_CALENDAR))
  add("contacts.search",granted(Manifest.permission.READ_CONTACTS));add("contacts.create",granted(Manifest.permission.WRITE_CONTACTS)&&granted(Manifest.permission.READ_CONTACTS))
  add("apps.list",true);add("apps.usage",usageGranted());add("apps.launch",true)
  add("notifications.list",SignalConfig.accessGranted(context));add("notifications.dismiss",SignalConfig.accessGranted(context))
  add("health.summary",healthPermissions.contains(HealthPermission.getReadPermission(StepsRecord::class)),hc)
  add("alarm.set",true);add("alarm.show",true)
  add("location.last",PhoneContext.locationGranted(context)&&PhoneContext.shareLocation(context))
  add("media.list",if(Build.VERSION.SDK_INT>=33)granted(Manifest.permission.READ_MEDIA_IMAGES) else granted(Manifest.permission.READ_EXTERNAL_STORAGE))
  add("device.status",true);add("device.vibrate",true);add("device.volume",true);add("device.torch",granted(Manifest.permission.CAMERA))
  return caps
 }
 private fun query(uri:Uri,columns:Array<String>,selection:String?=null,args:Array<String>?=null,sort:String?=null,limit:Int=100):JSONArray{
  val rows=JSONArray();cr.query(uri,columns,selection,args,sort)?.use{c->while(c.moveToNext()&&rows.length()<limit){val row=JSONObject();columns.forEachIndexed{i,k->row.put(k,if(c.isNull(i))JSONObject.NULL else c.getString(i))};rows.put(row)}};return rows
 }
 suspend fun execute(tool:String,a:JSONObject):JSONObject{
  val cap=capabilities().objects().firstOrNull{it.optString("tool")==tool}?:error("未注册能力")
  if(!cap.optBoolean("available",true))error("系统能力不可用")
  if(!cap.optBoolean("permission"))throw SecurityException("手机权限尚未开放")
  return when(tool){
   "device.status"->{val battery=context.registerReceiver(null,IntentFilter(Intent.ACTION_BATTERY_CHANGED));JSONObject().put("model",Build.MODEL).put("sdk",Build.VERSION.SDK_INT).put("battery",battery?.getIntExtra(BatteryManager.EXTRA_LEVEL,-1)).put("charging",battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED,0)!=0).put("source","Android")}
   "device.vibrate"->{val v=context.getSystemService(Vibrator::class.java);v.vibrate(VibrationEffect.createOneShot(a.optLong("milliseconds",100).coerceIn(20,1000),VibrationEffect.DEFAULT_AMPLITUDE));JSONObject().put("requested",true).put("physical_confirmation_required",true)}
   "device.volume"->{val am=context.getSystemService(AudioManager::class.java);val value=a.getInt("value").coerceIn(0,am.getStreamMaxVolume(AudioManager.STREAM_MUSIC));am.setStreamVolume(AudioManager.STREAM_MUSIC,value,0);JSONObject().put("value",am.getStreamVolume(AudioManager.STREAM_MUSIC)).put("verified",am.getStreamVolume(AudioManager.STREAM_MUSIC)==value)}
   "device.torch"->{val cam=context.getSystemService(CameraManager::class.java);val id=cam.cameraIdList.firstOrNull{cam.getCameraCharacteristics(it).get(android.hardware.camera2.CameraCharacteristics.FLASH_INFO_AVAILABLE)==true}?:error("无闪光灯");cam.setTorchMode(id,a.getBoolean("enabled"));JSONObject().put("requested",true).put("physical_confirmation_required",true)}
   "apps.list"->{val i=Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);val rows=JSONArray();context.packageManager.queryIntentActivities(i,0).take(150).forEach{rows.put(JSONObject().put("package",it.activityInfo.packageName).put("name",it.loadLabel(context.packageManager)))};JSONObject().put("items",rows).put("coverage","可见的启动器应用")}
   "apps.usage"->{val now=System.currentTimeMillis();val start=a.optLong("start",now-86400000).coerceAtLeast(now-30L*86400000);val rows=JSONArray();context.getSystemService(UsageStatsManager::class.java).queryUsageStats(UsageStatsManager.INTERVAL_DAILY,start,now).forEach{rows.put(JSONObject().put("package",it.packageName).put("foreground_ms",it.totalTimeInForeground).put("last_used",it.lastTimeUsed))};JSONObject().put("items",rows).put("start",start).put("end",now)}
   "apps.launch"->{val intent=context.packageManager.getLaunchIntentForPackage(a.getString("package"))?:error("找不到应用入口");context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));JSONObject().put("requested",true).put("physical_confirmation_required",true)}
   "contacts.search"->{val q=a.optString("query","");JSONObject().put("items",query(ContactsContract.CommonDataKinds.Phone.CONTENT_URI,arrayOf(ContactsContract.CommonDataKinds.Phone.CONTACT_ID,ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,ContactsContract.CommonDataKinds.Phone.NUMBER),"display_name LIKE ?",arrayOf("%$q%")))}
   "contacts.create"->{val name=a.getString("name");val number=a.getString("phone");val ops=arrayListOf(ContentProviderOperation.newInsert(ContactsContract.RawContacts.CONTENT_URI).withValue(ContactsContract.RawContacts.ACCOUNT_TYPE,null).withValue(ContactsContract.RawContacts.ACCOUNT_NAME,null).build(),ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI).withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID,0).withValue(ContactsContract.Data.MIMETYPE,ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE).withValue(ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME,name).build(),ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI).withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID,0).withValue(ContactsContract.Data.MIMETYPE,ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE).withValue(ContactsContract.CommonDataKinds.Phone.NUMBER,number).build());val result=cr.applyBatch(ContactsContract.AUTHORITY,ops);val raw=ContentUris.parseId(result[0].uri!!);val read=query(ContactsContract.Data.CONTENT_URI,arrayOf(ContactsContract.Data.RAW_CONTACT_ID,ContactsContract.Data.DATA1),"raw_contact_id=?",arrayOf(raw.toString()));JSONObject().put("raw_contact_id",raw).put("readback",read).put("verified",read.length()>=2)}
   "calendar.list"->{val start=a.optLong("start",System.currentTimeMillis()-7L*86400000);val end=a.optLong("end",System.currentTimeMillis()+30L*86400000);require(end>start&&end-start<=60L*86400000);val uri=CalendarContract.Instances.CONTENT_URI.buildUpon();ContentUris.appendId(uri,start);ContentUris.appendId(uri,end);JSONObject().put("calendars",query(CalendarContract.Calendars.CONTENT_URI,arrayOf("_id","calendar_displayName","account_name","calendar_access_level"))).put("items",query(uri.build(),arrayOf("event_id","title","begin","end","calendar_displayName"),sort="begin ASC",limit=250)).put("source","手机 CalendarProvider").put("start",start).put("end",end)}
   "calendar.create"->{val start=a.getLong("start");val end=a.getLong("end");require(end>start);val values=ContentValues().apply{put(CalendarContract.Events.CALENDAR_ID,a.getLong("calendar_id"));put(CalendarContract.Events.TITLE,a.getString("title"));put(CalendarContract.Events.DTSTART,start);put(CalendarContract.Events.DTEND,end);put(CalendarContract.Events.EVENT_TIMEZONE,"Asia/Shanghai");put(CalendarContract.Events.DESCRIPTION,a.optString("description"))};val uri=cr.insert(CalendarContract.Events.CONTENT_URI,values)?:error("日历写入失败");val read=query(uri,arrayOf("_id","title","dtstart","dtend"));JSONObject().put("id",ContentUris.parseId(uri)).put("readback",read).put("verified",read.length()==1)}
   "calendar.update"->{val id=a.getLong("id");val uri=ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI,id);val old=query(uri,arrayOf("_id","title","dtstart","dtend","description","hasAttendeeData","calendar_id"));val event=old.optJSONObject(0)?:error("事件不存在");require(event.optString("dtstart").toLong()==a.getLong("expected_start")){"事件已改变，请刷新"};require(!event.optString("description").contains("固定")){"固定安排不可调整"};val attendees=query(CalendarContract.Attendees.CONTENT_URI,arrayOf("_id"),"event_id=?",arrayOf(id.toString()));require(attendees.length()==0){"共享事件需要具体交办"};val start=a.getLong("start");val end=a.getLong("end");require(end>start);val overlaps=query(CalendarContract.Events.CONTENT_URI,arrayOf("_id"),"dtstart < ? AND dtend > ? AND _id != ?",arrayOf(end.toString(),start.toString(),id.toString()));require(overlaps.length()==0){"时间冲突"};val count=cr.update(uri,ContentValues().apply{put("dtstart",start);put("dtend",end)},"dtstart=?",arrayOf(a.getLong("expected_start").toString()));val read=query(uri,arrayOf("_id","title","dtstart","dtend"));JSONObject().put("verified",count==1&&read.optJSONObject(0)?.optString("dtstart")==start.toString()).put("readback",read).put("undo",JSONObject().put("id",id).put("expected_start",start).put("start",event.optString("dtstart").toLong()).put("end",event.optString("dtend").toLong()))}
   "notifications.list"->JSONObject().put("items",NodeNotificationAccess.list()).put("source","Android active notifications")
   "notifications.dismiss"->{NodeNotificationAccess.dismiss(a.getString("key"));JSONObject().put("verified",NodeNotificationAccess.list().objects().none{it.optString("key")==a.getString("key")})}
   "alarm.set"->{val hour=a.getInt("hour");val minute=a.getInt("minute");require(hour in 0..23&&minute in 0..59);val i=Intent(AlarmClock.ACTION_SET_ALARM).putExtra(AlarmClock.EXTRA_HOUR,hour).putExtra(AlarmClock.EXTRA_MINUTES,minute).putExtra(AlarmClock.EXTRA_MESSAGE,a.optString("label","Com! 提醒")).putExtra(AlarmClock.EXTRA_SKIP_UI,false).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);context.startActivity(i);JSONObject().put("requested",true).put("requires_system_confirmation",true)}
   "alarm.show"->{context.startActivity(Intent(AlarmClock.ACTION_SHOW_ALARMS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));JSONObject().put("requested",true)}
   "location.last"->{val lm=context.getSystemService(LocationManager::class.java);val l=lm.getProviders(true).mapNotNull{runCatching{lm.getLastKnownLocation(it)}.getOrNull()}.maxByOrNull{it.time}?:error("暂无位置记录");JSONObject().put("latitude",l.latitude).put("longitude",l.longitude).put("accuracy_meters",l.accuracy).put("measured_at",l.time).put("source","Android last known location").put("is_live",false)}
   "media.list"->JSONObject().put("items",query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,arrayOf("_id","display_name","date_taken","mime_type"),sort="date_taken DESC",limit=50)).put("coverage",if(Build.VERSION.SDK_INT>=34)"当前权限允许的图片，包括部分照片授权范围"else"可读取图片")
   "health.summary"->health(a)
   else->error("未实现能力")
  }
 }
 private suspend fun health(a:JSONObject):JSONObject{
  val hc=HealthConnectClient.getOrCreate(context);val perms=hc.permissionController.getGrantedPermissions()
  val bg="android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND"
  if(!PhoneNodeService.appVisible&&!perms.contains(bg))throw SecurityException("Health Connect 后台读取未授权")
  val end=Instant.now();val days=a.optInt("days",1).coerceIn(1,90)
  if(days>30&&!perms.contains("android.permission.health.READ_HEALTH_DATA_HISTORY"))throw SecurityException("Health Connect 历史读取未授权")
  val start=end.minus(Duration.ofDays(days.toLong()))
  val metrics=mutableSetOf<androidx.health.connect.client.aggregate.AggregateMetric<*>>(StepsRecord.COUNT_TOTAL)
  if(perms.contains(HealthPermission.getReadPermission(HeartRateRecord::class)))metrics.add(HeartRateRecord.BPM_AVG)
  val result=hc.aggregate(AggregateRequest(metrics=metrics,timeRangeFilter=TimeRangeFilter.between(start,end)))
  return JSONObject().put("steps",result[StepsRecord.COUNT_TOTAL]?:JSONObject.NULL).put("heart_rate_average",result[HeartRateRecord.BPM_AVG]?:JSONObject.NULL).put("start",start.toString()).put("end",end.toString()).put("source","Health Connect aggregate").put("origins",JSONArray(result.dataOrigins.map{it.packageName})).put("missing_reason",if(result[StepsRecord.COUNT_TOTAL]==null)"指定时间内未读到数据"else JSONObject.NULL).put("deduplicated",true)
 }
}
object NodeNotificationAccess{
 @Volatile var service:android.service.notification.NotificationListenerService?=null
 fun list():JSONArray{val s=service?:error("通知服务尚未连接");return JSONArray(s.activeNotifications.take(100).map{n->JSONObject().put("key",n.key).put("package",n.packageName).put("posted_at",n.postTime).put("title",n.notification.extras.getCharSequence("android.title")?.toString()).put("text",n.notification.extras.getCharSequence("android.text")?.toString())})}
 fun dismiss(key:String){val s=service?:error("通知服务尚未连接");s.cancelNotification(key)}
}
