package work.eddie.sessions
import android.app.*
import android.content.*
import android.os.*
import androidx.core.app.NotificationCompat
import androidx.work.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.*
import org.json.*
import java.util.UUID
import java.util.concurrent.TimeUnit

class PhoneNodeService:Service(){
 private val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
 private lateinit var store:Store
 private var socket:WebSocket?=null
 private var runner:Job?=null
 private val mutex=Mutex()
 override fun onBind(intent:Intent?)=null
 override fun onCreate(){super.onCreate();store=Store(this)
  val journal=store.cachedSecure("node-invocations")
  journal.keys().forEach{id->if(journal.getJSONObject(id).optString("status")=="executing")journal.put(id,JSONObject().put("type","result").put("id",id).put("status","unknown").put("result",JSONObject().put("reason","上次执行中断；回读后核实，不重放")))}
  store.secureCache("node-invocations",journal)
 }
 override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int{
  if(!enabled(this)||store.token.isBlank()){stopSelf();return START_NOT_STICKY}
  getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("phone-node","Com! 手机节点",NotificationManager.IMPORTANCE_LOW))
  val open=PendingIntent.getActivity(this,23,Intent(this,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE)
  startForeground(923,NotificationCompat.Builder(this,"phone-node").setSmallIcon(R.drawable.ic_launcher).setContentTitle("Com! 手机节点已启用").setContentText("Hermes 可调用已授权的手机工具").setContentIntent(open).setOngoing(true).build())
  if(runner==null)runner=scope.launch{while(isActive&&enabled(this@PhoneNodeService)){
   try{
    register(store)
    val completed=CompletableDeferred<Unit>()
    val client=OkHttpClient.Builder().pingInterval(20,TimeUnit.SECONDS).build()
    socket=client.newWebSocket(Request.Builder().url(store.base.replaceFirst("https://","wss://")+"/personal/devices/"+nodeId(store)+"/ws").header("Authorization","Bearer ${store.token}").build(),object:WebSocketListener(){
     private var heartbeat:Job?=null
     override fun onOpen(ws:WebSocket,response:Response){online=true;heartbeat=scope.launch{runCatching{flush(store)};while(isActive){delay(20000);ws.send(JSONObject().put("type","heartbeat").toString())}}}
     override fun onMessage(ws:WebSocket,text:String){scope.launch{runCatching{val data=JSONObject(text);if(data.optString("type")=="invocation")invoke(data,ws)}}}
     override fun onClosing(ws:WebSocket,code:Int,reason:String){ws.close(code,reason)}
     override fun onClosed(ws:WebSocket,code:Int,reason:String){online=false;heartbeat?.cancel();completed.complete(Unit)}
     override fun onFailure(ws:WebSocket,t:Throwable,response:Response?){online=false;heartbeat?.cancel();completed.complete(Unit)}
    })
    completed.await();client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()
   }catch(_:Exception){online=false}
   delay(15000)
  }}
  return START_STICKY
 }
 private suspend fun invoke(data:JSONObject,ws:WebSocket)=mutex.withLock{
  val id=data.getString("id");val journal=store.cachedSecure("node-invocations");val old=journal.optJSONObject(id)
  if(old!=null){val result=if(old.optString("status")=="executing")JSONObject().put("type","result").put("id",id).put("status","unknown").put("result",JSONObject().put("reason","执行中断，先回读；不会重放"))else old;ws.send(result.toString());return@withLock}
  journal.put(id,JSONObject().put("id",id).put("status","executing"));store.secureCache("node-invocations",journal)
  ws.send(JSONObject().put("type","ack").put("id",id).toString())
  val result=JSONObject().put("type","result").put("id",id)
  try{val payload=withTimeout(data.optLong("timeout",30)*1000){PhoneNodeTools(this@PhoneNodeService).execute(data.getString("tool"),data.optJSONObject("args")?:JSONObject())};result.put("status","succeeded").put("result",payload)}
  catch(e:Exception){result.put("status",if(e is SecurityException)"permission_denied"else if(e is TimeoutCancellationException)"unknown"else"failed").put("result",JSONObject().put("reason",e.message?:"执行失败"))}
  journal.put(id,result);store.secureCache("node-invocations",journal);ws.send(result.toString())
 }
 override fun onDestroy(){online=false;socket?.close(1000,"服务停止");scope.cancel();super.onDestroy()}
 companion object{
  @Volatile var online=false
  @Volatile var appVisible=false
  fun enabled(context:Context)=context.getSharedPreferences("workbench",0).getBoolean("node-enabled",false)
  fun nodeId(store:Store):String=store.prefs.getString("node-id",null)?: ("node_"+UUID.randomUUID().toString().replace("-","")).also{store.prefs.edit().putString("node-id",it).commit()}
  fun enable(context:Context,value:Boolean){context.getSharedPreferences("workbench",0).edit().putBoolean("node-enabled",value).apply();if(value){context.startForegroundService(Intent(context,PhoneNodeService::class.java));WorkManager.getInstance(context).enqueueUniquePeriodicWork("phone-node-sync",ExistingPeriodicWorkPolicy.KEEP,PeriodicWorkRequestBuilder<PhoneNodeSyncWorker>(15,TimeUnit.MINUTES).setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build())}else{context.stopService(Intent(context,PhoneNodeService::class.java));WorkManager.getInstance(context).cancelUniqueWork("phone-node-sync")}}
  suspend fun register(store:Store){store.request("/personal/devices/register",JSONObject().put("id",nodeId(store)).put("name",Build.MODEL).put("capabilities",PhoneNodeTools(store.context).capabilities()))}
  suspend fun flush(store:Store){val journal=store.cachedSecure("node-invocations");journal.keys().forEach{id->val row=journal.getJSONObject(id);if(row.optString("type")=="result")store.request("/personal/devices/${nodeId(store)}/results",row)}}
 }
}
class PhoneNodeSyncWorker(context:Context,params:WorkerParameters):CoroutineWorker(context,params){
 override suspend fun doWork():Result{
  if(!PhoneNodeService.enabled(applicationContext))return Result.success()
  val store=Store(applicationContext)
  return try{PhoneNodeService.register(store);PhoneNodeService.flush(store);Result.success()}catch(_:Exception){Result.retry()}
 }
}
