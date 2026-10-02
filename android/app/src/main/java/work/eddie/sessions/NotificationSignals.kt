package work.eddie.sessions

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Handler
import android.os.HandlerThread
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

private const val SIGNAL_QUEUE_FILE="personal-signals.enc"
private const val SIGNAL_REMINDER_FILE="personal-signal-reminders.enc"
private const val SIGNAL_QUEUE_LIMIT=500
private const val SIGNAL_RECENT_LIMIT=1024
private const val SIGNAL_MAX_AGE_MS=29L*24*60*60*1000

/** Deliberately narrow default. The default SMS app is also resolved from Android at runtime. */
fun signalPackageAllowed(packageName:String,ownPackage:String,defaultSmsPackage:String?,scope:String):Boolean{
 if(packageName.isBlank()||packageName==ownPackage||packageName in setOf("android","com.android.systemui","com.miui.systemui"))return false
 if(scope=="all")return true
 return packageName=="com.tencent.mm"||packageName==defaultSmsPackage&&defaultSmsPackage.isNotBlank()
  ||packageName in setOf("com.android.mms","com.miui.mms","com.google.android.apps.messaging","com.samsung.android.messaging")
}

private val privateContent=Regex(
 "验证码|驗證碼|认证码|認證碼|校验码|校驗碼|动态码|動態碼|动态口令|動態口令|一次性密码|一次性密碼|登录码|登入碼|安全码|取件码|密码|密碼|银行卡|信用卡|借记卡|账户余额|帐户余额|转账|轉帳|微信支付|支付宝|支付密码|付款码|收款码|身份证|身分證|护照|護照|诊断|診斷|处方|處方|verification[ -]?code|one[ -]?time[ -]?(?:code|password)|security[ -]?code|passcode|password|bank[ -]?account|credit[ -]?card|payment|transaction|account[ -]?balance|medical|diagnosis|prescription|\\botp\\b|\\b2fa\\b|\\bmfa\\b",
 RegexOption.IGNORE_CASE,
)
private val likelyNumericCode=Regex("(?<!\\d)\\d{4,8}(?!\\d)")

fun signalIsSensitive(title:String,text:String):Boolean{
 val content="$title $text"
 return privateContent.containsMatchIn(content)||likelyNumericCode.containsMatchIn(content)
}

fun signalId(packageName:String,notificationKey:String,postedAtMs:Long,title:String,text:String):String{
 val input=listOf(packageName,notificationKey,postedAtMs.toString(),title,text).joinToString("\u0000")
 return MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8)).joinToString(""){"%02x".format(it)}
}

/** Any unexpected ID means the server response cannot be trusted as an ACK. */
fun signalAckIds(sent:Set<String>,accepted:Set<String>,duplicates:Set<String>):Set<String>?{
 val all=accepted+duplicates
 return if(all.all{it in sent})all else null
}

fun newImportantSignalIds(initialized:Boolean,seen:Set<String>,importantIds:Set<String>):Set<String> =
 if(initialized)importantIds-seen else emptySet()

private data class SignalPayload(
 val id:String,val packageName:String,val title:String,val text:String,val postedAtMs:Long,
 val conversationId:String?,val replyCapable:Boolean,
){
 fun json()=JSONObject().put("id",id).put("package_name",packageName).put("title",title)
  .put("text",text).put("posted_at_ms",postedAtMs).put("sensitive",false)
  .put("reply_capable",replyCapable).apply{if(!conversationId.isNullOrBlank())put("conversation_id",conversationId)}
}

private fun notificationSignal(context:Context,sbn:StatusBarNotification):SignalPayload?{
 val notification=sbn.notification
 if(notification.flags and (Notification.FLAG_GROUP_SUMMARY or Notification.FLAG_ONGOING_EVENT)!=0)return null
 if(notification.visibility==Notification.VISIBILITY_SECRET)return null
 if(notification.category in setOf(Notification.CATEGORY_CALL,Notification.CATEGORY_SYSTEM,Notification.CATEGORY_SERVICE,Notification.CATEGORY_TRANSPORT,Notification.CATEGORY_PROGRESS))return null
 val defaultSms=runCatching{Telephony.Sms.getDefaultSmsPackage(context)}.getOrNull()
 val packageName=sbn.packageName
 if(!signalPackageAllowed(packageName,context.packageName,defaultSms,SignalConfig.scope(context)))return null
 val extras=notification.extras?:return null
 val rawTitle=runCatching{extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()}.getOrDefault("")
 val rawPreview=runCatching{extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()}.getOrDefault("")
 val rawBigText=runCatching{extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString().orEmpty()}.getOrDefault("")
 // Avoid truncating away a secret marker. Oversized notification bodies are skipped.
 if(rawTitle.length>180||rawPreview.length>1000||rawBigText.length>1000)return null
 val title=rawTitle.replace(Regex("\\s+")," ").trim()
 if(signalIsSensitive(title,rawPreview)||signalIsSensitive(title,rawBigText))return null
 val rawText=rawBigText.ifBlank{rawPreview}
 val text=rawText.replace(Regex("\\s+")," ").trim()
 if(title.isBlank()&&text.isBlank())return null
 val posted=sbn.postTime
 val now=System.currentTimeMillis()
 if(posted<now-SIGNAL_MAX_AGE_MS||posted>now+300_000)return null
 val shortcut=notification.shortcutId?.takeIf{it.isNotBlank()&&it.length<=256}
 val reply=notification.actions?.any{action->action.remoteInputs?.any{it.allowFreeFormInput}==true}==true
 return SignalPayload(signalId(packageName,sbn.key,posted,title,text),packageName,title,text,posted,shortcut,reply)
}

object SignalConfig{
 private fun prefs(context:Context)=context.getSharedPreferences("personal-signals",Context.MODE_PRIVATE)
 fun enabled(context:Context)=prefs(context).getBoolean("enabled",false)
 fun scope(context:Context)=prefs(context).getString("scope","messages")?:"messages"
 fun setScope(context:Context,value:String){require(value in setOf("messages","all"));prefs(context).edit().putString("scope",value).apply()}
 fun reminders(context:Context)=prefs(context).getBoolean("important_reminders",true)
 /** 主动强度：quiet 安静 / standard 标准 / active 积极 */
 fun intensity(context:Context)=prefs(context).getString("intensity","standard")?:"standard"
 fun setIntensity(context:Context,value:String){require(value in setOf("quiet","standard","active"));prefs(context).edit().putString("intensity",value).apply()}
 fun setReminders(context:Context,value:Boolean){
  prefs(context).edit().putBoolean("important_reminders",value).apply()
  if(!value)context.getSystemService(NotificationManager::class.java).cancel(91314)
 }
 fun accessGranted(context:Context):Boolean=runCatching{
  context.getSystemService(NotificationManager::class.java)
   .isNotificationListenerAccessGranted(ComponentName(context,PersonalNotificationListener::class.java))
 }.getOrDefault(false)
 fun setEnabled(context:Context,value:Boolean){
  prefs(context).edit().putBoolean("enabled",value).apply()
  if(value)SignalSync.schedule(context)
  else{SignalSync.cancel(context);context.getSystemService(NotificationManager::class.java).cancel(91314);SignalQueue(context).clear()}
 }
 fun markListen(context:Context){prefs(context).edit().putLong("last_listen_ms",System.currentTimeMillis()).apply()}
 fun markCaptured(context:Context){prefs(context).edit().putLong("last_capture_ms",System.currentTimeMillis()).apply()}
 fun markConnected(context:Context){prefs(context).edit().putLong("last_connected_ms",System.currentTimeMillis()).apply()}
 fun markUploaded(context:Context){prefs(context).edit().putLong("last_upload_ms",System.currentTimeMillis()).apply()}
 fun markPoll(context:Context,error:String=""){prefs(context).edit().putLong("last_poll_ms",System.currentTimeMillis()).putString("last_poll_error",error).apply()}
 fun lastListen(context:Context)=prefs(context).getLong("last_listen_ms",0)
 fun lastCaptured(context:Context)=prefs(context).getLong("last_capture_ms",0)
 fun lastConnected(context:Context)=prefs(context).getLong("last_connected_ms",0)
 fun lastUpload(context:Context)=prefs(context).getLong("last_upload_ms",0)
 fun lastPoll(context:Context)=prefs(context).getLong("last_poll_ms",0)
 fun lastPollError(context:Context)=prefs(context).getString("last_poll_error","").orEmpty()
}

data class SignalQueueStats(val pending:Int,val dropped:Int)

/** All queue reads and writes share one process lock and one Keystore encrypted file. */
class SignalQueue(private val context:Context){
 private val store=Store(context)
 private fun read():JSONObject{
  val data=store.secureCacheOrNull(SIGNAL_QUEUE_FILE)?:return JSONObject().put("events",JSONArray()).put("recent_ids",JSONArray()).put("dropped",0)
  check(data.optJSONArray("events")!=null&&data.optJSONArray("recent_ids")!=null){"加密通知队列无法读取"}
  return data
 }
 private fun save(data:JSONObject)=store.secureCache(SIGNAL_QUEUE_FILE,data)
 fun add(event:JSONObject):Boolean=synchronized(lock){
  if(!SignalConfig.enabled(context)||!SignalConfig.accessGranted(context))return@synchronized false
  val data=read()
  val id=event.getString("id")
  val old=data.array("events")
  val recent=data.optJSONArray("recent_ids")?:JSONArray()
  if(old.any{it.optString("id")==id}||(0 until recent.length()).any{recent.optString(it)==id})return@synchronized false
  val now=System.currentTimeMillis()
  val valid=old.filter{it.optLong("posted_at_ms")>=now-SIGNAL_MAX_AGE_MS}.toMutableList()
  valid.add(event)
  val overflow=(valid.size-SIGNAL_QUEUE_LIMIT).coerceAtLeast(0)
  val kept=valid.drop(overflow)
  data.put("events",JSONArray(kept)).put("dropped",data.optInt("dropped")+overflow)
  save(data)
  true
 }
 fun batch(limit:Int=50):List<JSONObject> = synchronized(lock){
  val data=read()
  val now=System.currentTimeMillis()
  val valid=data.array("events").filter{it.optLong("posted_at_ms")>=now-SIGNAL_MAX_AGE_MS}
  if(valid.size!=data.array("events").size){data.put("events",JSONArray(valid));save(data)}
  valid.take(limit.coerceIn(1,50)).map{JSONObject(it.toString())}
 }
 fun ack(ids:Set<String>)=synchronized(lock){
  if(ids.isEmpty())return@synchronized
  val data=read()
  val removed=data.array("events").filter{it.optString("id") in ids}
  data.put("events",JSONArray(data.array("events").filterNot{it.optString("id") in ids}))
  val recent=(0 until data.getJSONArray("recent_ids").length()).map{data.getJSONArray("recent_ids").optString(it)}+removed.map{it.optString("id")}
  data.put("recent_ids",JSONArray(recent.takeLast(SIGNAL_RECENT_LIMIT)))
  save(data)
 }
 fun stats():SignalQueueStats=synchronized(lock){val data=read();SignalQueueStats(data.array("events").size,data.optInt("dropped"))}
 fun clear()=synchronized(lock){
  File(context.filesDir,"cache/$SIGNAL_QUEUE_FILE").delete()
  File(context.filesDir,"cache/$SIGNAL_QUEUE_FILE.tmp").delete()
 }
 companion object{private val lock=Any()}
}

object SignalSync{
 private const val periodic="personal-signals-periodic"
 private const val immediate="personal-signals-immediate"
 private fun constraints()=Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
 fun schedule(context:Context){
  if(!SignalConfig.enabled(context))return
  WorkManager.getInstance(context).enqueueUniquePeriodicWork(periodic,ExistingPeriodicWorkPolicy.UPDATE,
   PeriodicWorkRequestBuilder<SignalsUploadWorker>(15,TimeUnit.MINUTES).setConstraints(constraints()).build())
  immediate(context)
 }
 fun immediate(context:Context){
  if(!SignalConfig.enabled(context)||!SignalConfig.accessGranted(context))return
  WorkManager.getInstance(context).enqueueUniqueWork(immediate,ExistingWorkPolicy.KEEP,
   OneTimeWorkRequestBuilder<SignalsUploadWorker>().setConstraints(constraints())
    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL,30,TimeUnit.SECONDS).build())
 }
 fun cancel(context:Context){
  val manager=WorkManager.getInstance(context)
  manager.cancelUniqueWork(periodic);manager.cancelUniqueWork(immediate)
 }
}

class SignalsUploadWorker(context:Context,params:WorkerParameters):CoroutineWorker(context,params){
 override suspend fun doWork():Result{
  if(!SignalConfig.enabled(applicationContext)||!SignalConfig.accessGranted(applicationContext))return Result.success()
  val store=Store(applicationContext)
  if(store.token.isBlank())return Result.success()
  val queue=SignalQueue(applicationContext)
  return try{
   repeat(20){
    if(!SignalConfig.enabled(applicationContext)||!SignalConfig.accessGranted(applicationContext))return Result.success()
    val batch=queue.batch()
    if(batch.isEmpty()){
     SignalReminderPoller.poll(applicationContext,store)
     return Result.success()
    }
    val sent=batch.map{it.getString("id")}.toSet()
    val reply=store.request("/personal/signals",JSONObject().put("events",JSONArray(batch)))
    val accepted=reply.optJSONArray("accepted_ids")?.stringIds()?:return Result.retry()
    val duplicates=reply.optJSONArray("duplicate_ids")?.stringIds()?:return Result.retry()
    val acknowledged=signalAckIds(sent,accepted,duplicates)?:return Result.retry()
    if(acknowledged.isEmpty())return Result.retry()
    queue.ack(acknowledged)
    SignalConfig.markUploaded(applicationContext)
    if(acknowledged.size<sent.size)return Result.retry()
   }
   Result.retry()
  }catch(e:java.util.concurrent.CancellationException){throw e}
   catch(_:Exception){Result.retry()}
 }
}

/** Remember reviewed IDs before posting, so retries and process restarts cannot repeat alerts. */
private class SignalReminderState(private val context:Context){
 private val store=Store(context)
 fun unseenImportant(items:List<JSONObject>):Int=synchronized(lock){
  val data=store.secureCacheOrNull(SIGNAL_REMINDER_FILE)?:JSONObject().put("initialized",false).put("seen_ids",JSONArray())
  check(data.optJSONArray("seen_ids")!=null){"提醒去重记录无法读取"}
  val ids=items.filter{it.optString("status")=="reviewed"&&it.optString("priority")=="important"}
   .map{it.optString("event_id")}.filter{it.matches(Regex("[a-f0-9]{64}"))}.distinct()
  val seen=data.arrayStrings("seen_ids")
  val first=!data.optBoolean("initialized")
  val count=newImportantSignalIds(!first,seen.toSet(),ids.toSet()).size
  data.put("initialized",true).put("seen_ids",JSONArray((seen+ids).distinct().takeLast(SIGNAL_RECENT_LIMIT)))
  store.secureCache(SIGNAL_REMINDER_FILE,data)
  count
 }
 companion object{private val lock=Any()}
}

private fun JSONObject.arrayStrings(key:String):List<String>{
 val array=optJSONArray(key)?:return emptyList()
 return (0 until array.length()).mapNotNull{array.optString(it).takeIf(String::isNotBlank)}
}

private object SignalReminderPoller{
 suspend fun poll(context:Context,store:Store){
  if(!SignalConfig.enabled(context)||!SignalConfig.accessGranted(context))return
  try{
   val response=store.request("/personal/signals?limit=100")
   if(response.optJSONArray("items")==null)error("通知巡检列表格式错误")
   val count=SignalReminderState(context).unseenImportant(response.array("items"))
   SignalConfig.markPoll(context)
   if(count>0&&SignalConfig.reminders(context))postNotice(context,count)
  }catch(e:java.util.concurrent.CancellationException){throw e}
   catch(_:Exception){SignalConfig.markPoll(context,"获取巡检结果失败")}
 }

 private fun postNotice(context:Context,count:Int){
  if(android.os.Build.VERSION.SDK_INT>=33&&context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)return
  val manager=context.getSystemService(NotificationManager::class.java)
  if(!manager.areNotificationsEnabled())return
  manager.createNotificationChannel(android.app.NotificationChannel("personal-important","Personal Agent 重要事项",NotificationManager.IMPORTANCE_LOW))
  val intent=Intent(context,MainActivity::class.java).putExtra("signal_activity",true)
   .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
  val pending=PendingIntent.getActivity(context,91314,intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
  val notice=Notification.Builder(context,"personal-important")
   .setSmallIcon(android.R.drawable.ic_dialog_info)
   .setContentTitle("Com! 有重要事项待查看")
   .setContentText(if(count==1)"一条通知分析结果已准备好"else"$count 条通知分析结果已准备好")
   .setContentIntent(pending).setAutoCancel(true).setOnlyAlertOnce(true)
   .setVisibility(Notification.VISIBILITY_PRIVATE).build()
  manager.notify(91314,notice)
 }
}

private fun JSONArray.stringIds():Set<String>?{
 val values=(0 until length()).map{opt(it)}
 return if(values.all{it is String})values.filterIsInstance<String>().toSet() else null
}

class PersonalNotificationListener:NotificationListenerService(){
 private lateinit var queueThread:HandlerThread
 private lateinit var queueHandler:Handler
 override fun onCreate(){super.onCreate();queueThread=HandlerThread("com-signal-queue").apply{start()};queueHandler=Handler(queueThread.looper)}
 override fun onListenerConnected(){
  super.onListenerConnected()
  SignalConfig.markConnected(this)
  if(SignalConfig.enabled(this))SignalSync.schedule(this)
 }
 override fun onNotificationPosted(sbn:StatusBarNotification){
  if(!SignalConfig.enabled(this)||!SignalConfig.accessGranted(this))return
  SignalConfig.markListen(this)
  val event=notificationSignal(this,sbn)?:return
  queueHandler.post{
   runCatching{if(SignalQueue(this).add(event.json())){SignalConfig.markCaptured(this);SignalSync.immediate(this)}}
  }
 }
 override fun onDestroy(){queueThread.quitSafely();super.onDestroy()}
}
