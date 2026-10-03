package work.eddie.sessions

import android.app.*
import android.content.*
import android.media.MediaRecorder
import android.os.SystemClock
import android.security.keystore.*
import android.util.Base64
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collectLatest
import org.json.*
import java.io.File
import java.net.*
import java.security.KeyStore
import java.util.UUID
import javax.crypto.*
import javax.crypto.spec.GCMParameterSpec

fun JSONArray.objects(): List<JSONObject> = (0 until length()).mapNotNull { optJSONObject(it) }
fun JSONObject.array(key:String)=optJSONArray(key)?.objects()?:emptyList()
fun String.shortPath()=trimEnd('/').substringAfterLast('/')
fun statusLabel(s:String)=when(s){"running"->"运行中";"submitted"->"已发送，等待处理";"waiting"->"需要你回应";"completed"->"本轮完成";"interrupted"->"已中断";"ended"->"会话已结束";"failed"->"执行失败";"ready"->"可以开始";else->"历史记录"}
data class ModelSelection(val model:String="",val effort:String="")
class MessageNotSubmittedException(message:String):Exception(message)

class Store(val context:Context) {
 val prefs=context.getSharedPreferences("workbench",0)
 private val dir=File(context.filesDir,"cache").apply{mkdirs()}
 var base:String
   get()=prefs.getString("base","")?:""
   set(v){require(v.startsWith("https://"));prefs.edit().putString("base",v.trimEnd('/')).apply()}
 private val secretKey:javax.crypto.SecretKey by lazy {
   val ks=KeyStore.getInstance("AndroidKeyStore").apply{load(null)}
   (ks.getKey("session-token",null) as? javax.crypto.SecretKey) ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply{init(KeyGenParameterSpec.Builder("session-token",KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())}.generateKey()
 }
 private fun key():javax.crypto.SecretKey=secretKey
 @Volatile private var tokenRaw:String?=null
 @Volatile private var tokenPlain:String=""
 var token:String
   get(){
     val raw=prefs.getString("token","")?:""
     if(raw.isEmpty())return ""
     if(raw==tokenRaw)return tokenPlain
     return runCatching {
       val decoded=Base64.decode(raw,Base64.NO_WRAP)
       val c=Cipher.getInstance("AES/GCM/NoPadding")
       c.init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,decoded.copyOfRange(0,12)))
       String(c.doFinal(decoded.copyOfRange(12,decoded.size))).also{tokenPlain=it;tokenRaw=raw}
     }.getOrDefault("")
   }
   set(v){val c=Cipher.getInstance("AES/GCM/NoPadding");c.init(Cipher.ENCRYPT_MODE,key());val enc=Base64.encodeToString(c.iv+c.doFinal(v.toByteArray()),Base64.NO_WRAP);prefs.edit().putString("token",enc).apply();tokenPlain=v;tokenRaw=enc}
 private fun encrypt(value:String):String{
   val cipher=Cipher.getInstance("AES/GCM/NoPadding")
   cipher.init(Cipher.ENCRYPT_MODE,key())
   return Base64.encodeToString(cipher.iv+cipher.doFinal(value.toByteArray(Charsets.UTF_8)),Base64.NO_WRAP)
 }
 private fun decrypt(value:String):String{
   val raw=Base64.decode(value,Base64.NO_WRAP)
   val cipher=Cipher.getInstance("AES/GCM/NoPadding")
   cipher.init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,raw.copyOfRange(0,12)))
   return String(cipher.doFinal(raw.copyOfRange(12,raw.size)),Charsets.UTF_8)
 }
 fun secureText(name:String):String=runCatching{decrypt(prefs.getString(name,"").orEmpty())}.getOrDefault("")
 fun saveSecureText(name:String,value:String,durable:Boolean=false){
   val edit=prefs.edit().apply{if(value.isBlank())remove(name) else putString(name,encrypt(value))}
   if(durable)check(edit.commit()){ "加密状态保存失败" } else edit.apply()
 }
 @Synchronized fun saveSecureTexts(values:Map<String,String>,durable:Boolean=false){
   val encrypted=values.mapValues{(_,value)->if(value.isBlank())"" else encrypt(value)}
   values.keys.forEach{persistJobs.remove(it)?.cancel();persistPending.remove(it)}
   val edit=prefs.edit()
   encrypted.forEach{(name,value)->if(value.isBlank())edit.remove(name) else edit.putString(name,value)}
   if(durable)check(edit.commit()){ "加密状态保存失败" } else edit.apply()
 }
 private val persistScope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
 private val persistPending=java.util.concurrent.ConcurrentHashMap<String,()->Unit>()
 private val persistJobs=java.util.concurrent.ConcurrentHashMap<String,Job>()
 @Synchronized private fun persistSoon(key:String,write:()->Unit){
   persistPending[key]=write
   persistJobs.remove(key)?.cancel()
   persistJobs[key]=persistScope.launch{delay(350);runPending(key)}
 }
 @Synchronized private fun runPending(key:String){persistPending.remove(key)?.invoke()}
 fun flushPending(){persistJobs.values.forEach{it.cancel()};persistJobs.clear();persistPending.keys.toList().forEach{runPending(it)}}
 fun saveSecureTextSoon(name:String,value:String)=persistSoon(name){saveSecureText(name,value)}
 fun savePrefSoon(name:String,value:String)=persistSoon(name){prefs.edit().putString(name,value).apply()}
 fun secureCache(name:String,value:JSONObject){
   val target=File(dir,name);val tmp=File(dir,"$name.tmp")
   tmp.writeText(encrypt(value.toString()))
   check(tmp.renameTo(target)){"加密数据保存失败"}
 }
 fun secureCacheOrNull(name:String):JSONObject?{
   val file=File(dir,name)
   return if(file.exists())JSONObject(decrypt(file.readText())) else null
 }
 fun cachedSecure(name:String)=runCatching{JSONObject(decrypt(File(dir,name).readText()))}.getOrDefault(JSONObject())
 init {
   val bootstrap=File(context.filesDir,"connection.json")
   if(bootstrap.exists()){runCatching{val c=JSONObject(bootstrap.readText());base=c.getString("base");token=c.getString("token")};bootstrap.delete()}
 }
 suspend fun request(path:String,body:JSONObject?=null,auth:Boolean=true):JSONObject=withContext(Dispatchers.IO){
   require(base.startsWith("https://")){"请先设置 HTTPS 服务地址"}
   val con=URL(base+path).openConnection() as HttpURLConnection
   con.connectTimeout=12000;con.readTimeout=60000;con.instanceFollowRedirects=false
   con.setRequestProperty("Accept","application/json")
   if(auth)con.setRequestProperty("Authorization","Bearer $token")
   try{
    if(body!=null){con.requestMethod="POST";con.doOutput=true;con.setRequestProperty("Content-Type","application/json");con.outputStream.use{it.write(body.toString().toByteArray())}}
    val code=con.responseCode;val raw=(if(code in 200..299)con.inputStream else con.errorStream)?.bufferedReader()?.use{it.readText()}?:"{}"
    val data=runCatching{JSONObject(raw)}.getOrDefault(JSONObject())
    if(code !in 200..299)error(data.optString("detail","连接失败：$code"))
    data
   }finally{con.disconnect()}
 }
 suspend fun streamConversation(onEvent:suspend (String,JSONObject)->Unit)=withContext(Dispatchers.IO){
   require(base.startsWith("https://")){"请先设置 HTTPS 服务地址"}
   val con=URL(base+"/personal/conversation/stream").openConnection() as HttpURLConnection
   con.connectTimeout=12000;con.readTimeout=45000;con.instanceFollowRedirects=false
   con.setRequestProperty("Accept","text/event-stream")
   con.setRequestProperty("Cache-Control","no-cache")
   con.setRequestProperty("Authorization","Bearer $token")
   val closeOnCancel=CoroutineScope(currentCoroutineContext()).launch(Dispatchers.IO){
     try{awaitCancellation()}finally{con.disconnect()}
   }
   try{
     check(con.responseCode in 200..299){"Pi 实时连接失败：${con.responseCode}"}
     con.inputStream.bufferedReader().use{reader->
       var kind="message"
       val data=StringBuilder()
       while(currentCoroutineContext().isActive){
         val line=reader.readLine()?:break
         when{
           line.isEmpty()->{
             if(data.isNotEmpty()){
               val payload=JSONObject(data.toString())
               withContext(Dispatchers.Main.immediate){onEvent(kind,payload)}
             }
             kind="message";data.setLength(0)
           }
           line.startsWith("event:")->kind=line.substringAfter(':').trim()
           line.startsWith("data:")->{
             if(data.isNotEmpty())data.append('\n')
             data.append(line.substringAfter(':').trimStart())
             check(data.length<=8_000_000){"Pi 实时事件过大"}
           }
         }
       }
     }
   }finally{closeOnCancel.cancel();con.disconnect()}
 }
 fun cache(name:String,value:JSONObject){val target=File(dir,name);val tmp=File(dir,"$name.tmp");tmp.writeText(value.toString());tmp.renameTo(target)}
 fun cached(name:String)=runCatching{JSONObject(File(dir,name).readText())}.getOrDefault(JSONObject())
 fun detailCache(id:String)= "detail-"+id.replace(':','-')+".json"
 fun offline(q:String,agent:String,role:String,cwd:String,after:Double):List<JSONObject>{
   val terms=q.lowercase().split(Regex("\\s+")).filter{it.isNotBlank()}
   return cached("list.json").array("sessions").mapNotNull { original->
     val s=JSONObject(original.toString());if(agent.isNotEmpty()&&s.optString("agent")!=agent || cwd.isNotEmpty()&&s.optString("cwd")!=cwd || s.optDouble("updated")<after)return@mapNotNull null
     val hits=cached(detailCache(s.getString("id"))).array("messages").filter{(role.isBlank()||it.optString("role")==role)&&terms.all{term->(it.optString("title")+it.optString("text")).lowercase().contains(term)}}
     if(terms.isNotEmpty()&&hits.isEmpty()&&(role.isNotEmpty()||!terms.all{s.optString("display_title").lowercase().contains(it)}))return@mapNotNull null
     s.put("matches",JSONArray(hits.map{it.optString("id")}));s.put("hit_count",hits.size);s.put("snippet",hits.firstOrNull()?.optString("text")?.take(180)?:"");s
   }
 }
 fun notifyStatus(sid:String,status:String,title:String){
   val old=prefs.getString("status:$sid",null);prefs.edit().putString("status:$sid",status).apply()
   if(old==null||old==status||status !in listOf("completed","failed","waiting")||!prefs.getBoolean("notifications",true))return
   val manager=context.getSystemService(NotificationManager::class.java)
   manager.createNotificationChannel(NotificationChannel("updates","会话状态",NotificationManager.IMPORTANCE_DEFAULT))
   val intent=Intent(context,MainActivity::class.java).putExtra("sid",sid).setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
   val pending=PendingIntent.getActivity(context,sid.hashCode(),intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
   runCatching{manager.notify(sid.hashCode(),Notification.Builder(context,"updates").setSmallIcon(android.R.drawable.ic_dialog_info).setContentTitle(statusLabel(status)+" · "+title.take(35)).setContentText("点击回到这个会话").setContentIntent(pending).setAutoCancel(true).build())}
 }
}

class WorkbenchModel(app:Application):AndroidViewModel(app) {
 val store=Store(app)
 var allRows by mutableStateOf(store.cached("list.json").array("sessions"))
 var allRowsFresh by mutableStateOf(false)
 var rows by mutableStateOf(allRows)
 var creatingMessage by mutableStateOf<OutgoingMessage?>(null)
 var creatingAgent by mutableStateOf("claude")
 var selected by mutableStateOf(store.prefs.getString("selected","")?:"")
 var detail by mutableStateOf(if(selected.isNotEmpty())store.cached(store.detailCache(selected)) else JSONObject())
 var live by mutableStateOf(JSONObject())
 var liveSessionId by mutableStateOf("")
 var liveFresh by mutableStateOf(false)
 var error by mutableStateOf("")
 var connected by mutableStateOf(false)
 var messageReferencesAvailable by mutableStateOf(false)
 var busy by mutableStateOf(false)
 var personal by mutableStateOf(store.cachedSecure("personal-overview.enc"))
 var personalFresh by mutableStateOf(false)
 var personalLoading by mutableStateOf(false)
 var personalError by mutableStateOf("")
 var hermes by mutableStateOf(store.cachedSecure("hermes-conversation.enc"))
 var hermesFresh by mutableStateOf(false)
 var hermesLoading by mutableStateOf(false)
 var hermesStreaming by mutableStateOf(false)
 var hermesReactionSequence by mutableIntStateOf(0)
 private val reactionFeedbackTracker=ReactionFeedbackTracker()
 var hermesError by mutableStateOf("")
 var hermesOutbox by mutableStateOf(readConversationOutbox(store.secureText("hermes-outbox"),store.secureText("hermes-pending")))
 val outgoingMessages=mutableStateListOf<OutgoingMessage>().apply{addAll(hermesOutbox.map{it.outgoing()})}
 private val hermesSendJobs=mutableMapOf<String,Job>()
 var hermesReference by mutableStateOf<JSONObject?>(null)
 val workReferences=mutableStateMapOf<String,JSONObject>()
 var hermesSending by mutableStateOf(false)
 var hermesSendNote by mutableStateOf("")
 var hermesDraft by mutableStateOf(store.secureText("hermes-draft"))
 val hermesPending:JSONObject get()=hermesOutbox.firstOrNull{it.state=="unknown"}?.body()?:JSONObject()
 var hermesVisible by mutableStateOf(true)
 var rootPage by mutableStateOf("hermes")
 var signals by mutableStateOf(store.cachedSecure("personal-signals-review.enc"))
 var signalsHealth by mutableStateOf(store.cachedSecure("personal-signals-health.enc"))
 var signalsFresh by mutableStateOf(false)
 var signalsHealthFresh by mutableStateOf(false)
 var signalsLoading by mutableStateOf(false)
 var signalsError by mutableStateOf("")
 var showSignalsActivity by mutableStateOf(false)
 var taskLedger by mutableStateOf(store.cachedSecure("personal-tasks.enc"))
 var taskLedgerFresh by mutableStateOf(false)
 var taskLedgerError by mutableStateOf("")
 var taskControlTarget by mutableStateOf("")
 var taskControlBusy by mutableStateOf("")
 var taskControlNote by mutableStateOf("")
 var workProposals by mutableStateOf(store.cachedSecure("personal-work-proposals.enc"))
 var workProposalsFresh by mutableStateOf(false)
 var workProposalsLoading by mutableStateOf(false)
 var workProposalsError by mutableStateOf("")
 var workProposalBusy by mutableStateOf("")
 var workProposalNote by mutableStateOf("")
 private var workApprovalIds=runCatching{JSONObject(store.secureText("work-approval-ids"))}.getOrDefault(JSONObject())
 private var hermesReconcile:Job?=null
 var externalHermesRoute by mutableIntStateOf(0)
 var externalTaskRoute by mutableIntStateOf(0)
 var taskDetailId by mutableStateOf("")
 var taskReturnMessageId by mutableStateOf("")
 var taskReturnPage by mutableStateOf("hermes")
 /** 二级页（日历／账本／通知巡检／任务台账）的真实入口，由一级页离开时记录。 */
 var secondaryReturnPage by mutableStateOf("hermes")
 var taskFilter by mutableStateOf("all")
 var hermesTargetMessageId by mutableStateOf("")
 private val hermesVoiceDir=File(app.filesDir,"hermes-voice").apply{mkdirs()}
 private var hermesRecorder:MediaRecorder?=null
 private var hermesRecordingFile:File?=null
 private var hermesVoiceStarted=0L
 private var hermesVoiceTimer:Job?=null
 var hermesVoicePhase by mutableStateOf("idle")
 var hermesVoiceSeconds by mutableIntStateOf(0)
 var hermesVoiceNote by mutableStateOf("")
 var hermesVoiceAutoSend by mutableStateOf<String?>(null)
 var hermesVoiceSaved by mutableStateOf(store.prefs.getString("hermes-voice-file","").orEmpty())
 var externalWorkRoute by mutableIntStateOf(0)
 var voiceDelivery by mutableStateOf("")
 private var voiceWatch:Job?=null
 var index by mutableStateOf(JSONObject())
 var q by mutableStateOf(store.prefs.getString("search","")?:"");var agent by mutableStateOf("");var role by mutableStateOf("");var cwd by mutableStateOf("");var days by mutableIntStateOf(0);var sort by mutableStateOf("relevance")
 var working by mutableStateOf(true);var archived by mutableStateOf(false)
 var queryInSession by mutableStateOf(store.prefs.getString("session-search","")?:"");var targetMessage by mutableStateOf("")
 val drafts=mutableStateMapOf<String,String>()
 private val selections=mutableStateMapOf<String,ModelSelection>()
 val catalogs=mutableStateMapOf<String,List<ModelChoice>>()
 val catalogLoading=mutableStateMapOf<String,Boolean>()
 val catalogErrors=mutableStateMapOf<String,String>()
 var active by mutableStateOf(true)
 var font by mutableFloatStateOf(store.prefs.getFloat("font",16f))
 init {viewModelScope.launch{snapshotFlow{q to queryInSession}.collectLatest{(global,local)->delay(400);store.prefs.edit().putString("search",global).putString("session-search",local).apply()}};viewModelScope.launch{while(true){if(active&&store.token.isNotEmpty())refreshPersonal();delay(60_000)}};viewModelScope.launch{snapshotFlow{active&&hermesVisible}.collectLatest{visible->
  hermesStreaming=false
  if(visible)while(currentCoroutineContext().isActive){
   if(store.token.isBlank()){delay(1000);continue}
   refreshHermes()
   try{store.streamConversation{kind,payload->applyHermesEvent(kind,payload)}}
   catch(e:CancellationException){throw e}
   catch(_:Exception){}
   finally{hermesStreaming=false}
   delay(1500)
  }
 }};viewModelScope.launch{var tick=0;while(true){if(active&&store.token.isNotEmpty()){
   if(tick%5==0)refresh()
   val id=selected
   if(id.isNotEmpty()){
    try{val l=store.request("/sessions/${enc(id)}/live");if(selected==id&&active){live=l;liveSessionId=id;liveFresh=true}}catch(_:Exception){if(selected==id)liveFresh=false}
    if(tick%5==0)refreshDetail(id)
   }
   tick++
 };delay(800)}}}
 fun enc(s:String)=URLEncoder.encode(s,"UTF-8")
 fun refreshPersonalNow(){viewModelScope.launch{refreshPersonal()}}
 fun refreshHermesNow(){viewModelScope.launch{refreshHermes()}}
 fun hermesVoicePermissionDenied(){hermesVoiceNote="请在系统设置中允许 Com! 使用麦克风。"}
 @Suppress("DEPRECATION")
 fun beginHermesVoice(){
   if(hermesVoicePhase!="idle"||hermesVoiceSaved.isNotBlank()||hermesDraft.isNotBlank()||store.token.isBlank())return
   val file=File(hermesVoiceDir,"${UUID.randomUUID()}.m4a")
   try{
     val recorder=MediaRecorder()
     hermesRecorder=recorder
     recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
     recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
     recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
     recorder.setAudioSamplingRate(16000)
     recorder.setAudioEncodingBitRate(64000)
     recorder.setOutputFile(file.absolutePath)
     recorder.prepare();recorder.start()
     hermesRecordingFile=file;hermesVoiceStarted=SystemClock.elapsedRealtime()
     hermesVoiceSeconds=0;hermesVoicePhase="recording";hermesVoiceNote="正在听你说话，点麦克风结束。"
     hermesVoiceTimer?.cancel();hermesVoiceTimer=viewModelScope.launch{while(hermesVoicePhase=="recording"){
       delay(1000);hermesVoiceSeconds=((SystemClock.elapsedRealtime()-hermesVoiceStarted)/1000).toInt()
       if(hermesVoiceSeconds>=60)finishHermesVoice()
     }}
   }catch(_:Exception){runCatching{hermesRecorder?.release()};hermesRecorder=null;file.delete();hermesVoicePhase="idle";hermesVoiceNote="录音无法开始，请检查麦克风权限或占用状态。"}
 }
 fun finishHermesVoice(transcribe:Boolean=true){
   if(hermesVoicePhase!="recording")return
   hermesVoiceTimer?.cancel();hermesVoiceTimer=null
   val file=hermesRecordingFile;hermesRecordingFile=null
   val stopped=runCatching{hermesRecorder?.stop()}.isSuccess
   runCatching{hermesRecorder?.release()};hermesRecorder=null;hermesVoicePhase="idle"
   if(!stopped||file==null||file.length()<512||SystemClock.elapsedRealtime()-hermesVoiceStarted<650){
     file?.delete();hermesVoiceNote="录音太短，请再说一次。";return
   }
   hermesVoiceSaved=file.name;store.prefs.edit().putString("hermes-voice-file",file.name).apply()
   if(transcribe)transcribeHermesVoice() else hermesVoiceNote="录音已保留，回到 Pi 可重试转写。"
 }
 fun transcribeHermesVoice(){
   if(hermesVoicePhase!="idle")return
   val file=File(hermesVoiceDir,hermesVoiceSaved)
   if(!hermesVoiceSaved.matches(Regex("[a-f0-9-]{36}\\.m4a"))||!file.exists()){hermesVoiceSaved="";store.prefs.edit().remove("hermes-voice-file").apply();return}
   hermesVoicePhase="transcribing";hermesVoiceNote="正在转写给 Pi…"
   viewModelScope.launch{
     try{
       val transcript=uploadVoice(store,file,file.nameWithoutExtension).optString("text").trim()
       check(transcript.isNotBlank()){"没有听清这段录音"}
       if(hermesDraft.isNotBlank())error("已有文字草稿，请先处理后再转写录音")
       updateHermesDraft(transcript)
       file.delete();hermesVoiceSaved="";store.prefs.edit().remove("hermes-voice-file").apply()
       hermesVoicePhase="idle"
       if(hermesFresh){
        hermesVoiceNote=""
        // Let the visible composer lay out the transcription before it clears.
        if(active&&hermesVisible)hermesVoiceAutoSend=transcript else sendHermes()
       }
       else hermesVoiceNote="已转写到草稿；连接 Pi 后点发送。"
     }catch(e:CancellationException){throw e}
      catch(e:Exception){hermesVoicePhase="idle";hermesVoiceNote="${e.message?:"转写失败"}；录音已保留，可重试或删除。"}
   }
 }
 fun consumeHermesVoiceSend(text:String):Boolean{
  if(hermesVoiceAutoSend!=text)return false
  hermesVoiceAutoSend=null
  return hermesDraft==text&&hermesFresh&&hermesVoicePhase=="idle"
 }
 fun discardHermesVoice(){
   if(hermesVoicePhase!="idle")return
   val file=File(hermesVoiceDir,hermesVoiceSaved)
   if(hermesVoiceSaved.matches(Regex("[a-f0-9-]{36}\\.m4a")))file.delete()
   hermesVoiceSaved="";store.prefs.edit().remove("hermes-voice-file").apply();hermesVoiceNote=""
 }
 fun refreshSignalsNow(){viewModelScope.launch{refreshSignals()}}
 fun refreshWorkProposalsNow(){viewModelScope.launch{refreshWorkProposals()}}
 fun resumeTask(id:String){
   if(taskControlBusy.isNotBlank()||!taskLedgerFresh||store.token.isBlank())return
   val task=taskLedger.array("items").firstOrNull{it.optString("id")==id}?:return
   if(task.optString("status")!="paused")return
   taskControlBusy=id;taskControlTarget=id;taskControlNote=""
   val key="task-resume-$id.enc"
   val old=store.cachedSecure(key)
   val body=JSONObject().put("request_id",old.optString("request_id").ifBlank{UUID.randomUUID().toString()})
   runCatching{store.secureCache(key,body)}.onFailure{taskControlBusy="";taskControlNote="继续请求未保存，尚未发送";return}
   viewModelScope.launch{
     try{
       val receipt=store.request("/personal/tasks/${enc(id)}/resume",body)
       taskControlNote=if(receipt.optString("status")=="unknown")"继续结果待核实，请查看执行事件" else "继续请求已受理"
       if(receipt.optString("status")!="unknown")runCatching{store.secureCache(key,JSONObject())}
       refreshWorkProposals()
     }catch(e:CancellationException){throw e}
      catch(e:Exception){taskControlNote="继续结果待核实，不会自动重复请求。"}
     finally{taskControlBusy=""}
   }
 }
 suspend fun refreshWorkProposals(){
   if(workProposalsLoading||store.token.isBlank())return
   workProposalsLoading=true;workProposalsError=""
   try{
     val recent=store.request("/personal/work/proposals?limit=20")
     if(recent.optJSONArray("items")==null)error("工作建议数据格式不完整")
     workProposals=recent;workProposalsFresh=true
     runCatching{store.secureCache("personal-work-proposals.enc",recent)}
   }catch(e:CancellationException){workProposalsLoading=false;throw e}
    catch(e:Exception){workProposalsFresh=false;workProposalsError=e.message?:"工作建议暂不可用"}
   try{
     val tasks=store.request("/personal/tasks")
     if(tasks.optJSONArray("items")==null)error("任务数据格式不完整")
     taskLedger=tasks;taskLedgerFresh=true;taskLedgerError=""
     runCatching{store.secureCache("personal-tasks.enc",tasks)}
     for(task in tasks.array("items")){
       val key="task-command-${task.optString("id")}-input.enc"
       val pending=store.cachedSecure(key)
       val receipt=task.array("inputs").firstOrNull{it.optString("request_id")==pending.optString("request_id")}
       if(receipt!=null&&receipt.optString("state") in setOf("delivered","failed","unsupported","blocked_authorization","blocked_state")){
         runCatching{store.secureCache(key,JSONObject())}
       }
     }
   }catch(e:CancellationException){throw e}
    catch(e:Exception){taskLedgerFresh=false;taskLedgerError=e.message?:"任务暂不可用"}
   finally{workProposalsLoading=false}
 }
 fun workApprovalId(id:String)=workApprovalIds.optString(id)
 private fun saveWorkApprovalId(id:String):String{
   val current=workApprovalIds.optString(id)
   if(current.isNotBlank())return current
   val requestId=UUID.randomUUID().toString()
   val updated=JSONObject(workApprovalIds.toString()).put(id,requestId)
   store.saveSecureText("work-approval-ids",updated.toString(),durable=true)
   workApprovalIds=updated
   return requestId
 }
 fun moveSupplement(taskId:String,inputId:String){
   if(taskControlBusy.isNotBlank()||!taskLedgerFresh)return
   val cacheKey="move-input-$inputId.enc"
   val old=store.cachedSecure(cacheKey)
   val body=JSONObject().put("request_id",old.optString("request_id").ifBlank{UUID.randomUUID().toString()})
   try{store.secureCache(cacheKey,body)}catch(e:Exception){hermesSendNote="请求未保存，尚未发送";return}
   taskControlBusy=taskId
   viewModelScope.launch{
    try{
     val result=store.request("/personal/tasks/${enc(taskId)}/inputs/${enc(inputId)}/new-item",body)
     hermesSendNote=result.optString("note")
     refreshHermes();refreshWorkProposals()
    }catch(e:CancellationException){throw e}
     catch(e:Exception){hermesSendNote="另开事项结果待核实；再次操作复用同一请求号"}
     finally{taskControlBusy=""}
   }
 }
 fun taskCommand(id:String,text:String,cancel:Boolean=false){
   if(taskControlBusy.isNotBlank()||!taskLedgerFresh||store.token.isBlank())return
   taskControlBusy=id;taskControlTarget=id;taskControlNote=""
   // Persist each command before sending; uncertain delivery is never silently retried.
   val key="task-command-$id-${if(cancel)"cancel" else "input"}"
   val old=store.cachedSecure("$key.enc")
   val requestId=old.optString("request_id").ifBlank{java.util.UUID.randomUUID().toString()}
   if(old.optString("text").isNotBlank()&&old.optString("text")!=text){taskControlBusy="";taskControlNote="上一条指令待核实，请先查看任务事件";return}
   val body=JSONObject().put("request_id",requestId).put("text",text)
   runCatching{store.secureCache("$key.enc",body)}.onFailure{taskControlBusy="";taskControlNote="请求未保存，尚未发送";return}
   viewModelScope.launch{
     try{
       val result=store.request("/personal/tasks/${enc(id)}/${if(cancel)"cancel" else "input"}",body)
       if(!cancel&&result.optString("delivery") in setOf("delivered","failed","unsupported","blocked_authorization","blocked_state"))runCatching{store.secureCache("$key.enc",JSONObject())}
       taskControlNote=if(cancel&&("unknown" in listOf(result.optString("delivery"),result.optString("cancel_delivery"))))"取消结果待核实，请查看执行事件" else if(cancel)when(result.optString("status")){
        "cancelled"->"任务已停止"
        "unknown"->"取消结果待核实，请查看执行事件"
        else->"取消已受理，等待执行器确认停止"
       } else when(result.optString("delivery")){
        "delivered"->"指令已送达目标回合，生效仍需查看执行结果"
        "unsupported"->"当前 Pi 执行会话不支持在线投递；未发送，请查看详情"
        "failed"->"工作器拒绝了指令；未自动重试"
        "blocked_state"->"任务状态不允许投递，请先核实"
        "blocked_authorization"->"指令等待明确授权，未投递"
        "unknown"->"指令送达待核实，不会自动重发"
        "pending_start"->"约束已保存，将在任务开始时送达"
        "worker_queued"->"执行器已接收，等待送达下一回合"
        else->"指令已受理，排队送达中"
       }
     }catch(e:Exception){taskControlNote="请求结果待核实；重试复用同一请求号"}
     finally{refreshWorkProposals();taskControlBusy=""}
   }
 }
 fun approveWorkProposal(id:String){
   if(workProposalBusy.isNotBlank()||!workProposalsFresh||store.token.isBlank())return
   val proposal=workProposals.array("items").firstOrNull{it.optString("id")==id}?:return
   if(proposal.optString("status")!="proposed"||proposal.optDouble("expires_at")<=System.currentTimeMillis()/1000.0)return
   val requestId=runCatching{saveWorkApprovalId(id)}.getOrElse{
     workProposalNote="审批请求未能保存，尚未启动工作。"
     return
   }
   workProposalBusy=id;workProposalNote=""
   viewModelScope.launch{
     try{
       val result=store.request("/personal/work/proposals/${enc(id)}/approve",JSONObject().put("request_id",requestId).put("explicit_authorization",true))
       if(result.optString("id")!=id||result.optString("approval_request_id")!=requestId)error("审批结果待核实")
       workProposalNote=when(result.optString("status")){
         "accepted"->"已批准并启动工作会话"
         "unknown"->"派发状态待核实，请在工作页检查；不会自动重发"
         else->"审批已收到，正在核对工作状态"
       }
     }catch(e:Exception){workProposalNote="审批结果待核实，请刷新工作建议并核对工作页；如需重试会复用同一请求号，不会自动重发。";workProposalsError=e.message?:"暂时无法核实审批结果"}
     finally{
       refreshWorkProposals()
       val latest=workProposals.array("items").firstOrNull{it.optString("id")==id}
       if(latest?.optString("status")=="accepted")workProposalNote="已批准并启动工作会话"
       else if(latest?.optString("status")=="unknown")workProposalNote="派发状态待核实，请在工作页检查；不会自动重发"
       workProposalBusy=""
     }
   }
 }
 fun rejectWorkProposal(id:String){
   if(workProposalBusy.isNotBlank()||!workProposalsFresh||store.token.isBlank())return
   val proposal=workProposals.array("items").firstOrNull{it.optString("id")==id}?:return
   if(proposal.optString("status")!="proposed"||(!proposal.isNull("approval_request_id")&&proposal.optString("approval_request_id").isNotBlank()))return
   workProposalBusy=id;workProposalNote=""
   viewModelScope.launch{
     try{
       val result=store.request("/personal/work/proposals/${enc(id)}/reject",JSONObject())
       if(result.optString("status")!="rejected")error("拒绝结果待核实")
       workProposalNote="已拒绝这项工作建议"
     }catch(e:Exception){workProposalNote="拒绝结果待核实，请刷新后检查状态。";workProposalsError=e.message?:"暂时无法核实拒绝结果"}
     finally{
       refreshWorkProposals()
       if(workProposals.array("items").firstOrNull{it.optString("id")==id}?.optString("status")=="rejected")workProposalNote="已拒绝这项工作建议"
       workProposalBusy=""
     }
   }
 }
 suspend fun refreshSignals(){
   if(signalsLoading||store.token.isBlank())return
   signalsLoading=true;signalsError=""
   try{
     val recent=store.request("/personal/signals?limit=50")
     if(recent.optJSONArray("items")==null)error("通知活动数据格式不完整")
     signals=recent;signalsFresh=true
     runCatching{store.secureCache("personal-signals-review.enc",recent)}
   }catch(e:Exception){signalsFresh=false;signalsError=e.message?:"通知活动暂不可用"}
   try{
     val health=store.request("/personal/signals/health")
     if(!health.has("pending")||!health.has("interval_minutes"))error("通知巡检状态格式不完整")
     signalsHealth=health;signalsHealthFresh=true
     runCatching{store.secureCache("personal-signals-health.enc",health)}
   }catch(e:Exception){signalsHealthFresh=false;signalsError=listOf(signalsError,e.message?:"巡检状态暂不可用").filter{it.isNotBlank()}.joinToString("；")}
   signalsLoading=false
 }
 fun updateHermesDraft(value:String){hermesDraft=value;if(value.isBlank())store.saveSecureText("hermes-draft","") else store.saveSecureTextSoon("hermes-draft",value)}
 private fun mergeHermesRows(existing:JSONArray?,changes:List<JSONObject>,key:String):JSONArray{
   // Existing rows are immutable snapshots; replace changed rows instead of
   // serializing every historical message for every streamed chunk.
   val rows=(existing?.objects()?:emptyList()).toMutableList()
   changes.forEach{change->
     val id=change.optString(key)
     if(id.isBlank())return@forEach
     val index=rows.indexOfFirst{it.optString(key)==id}
     if(index<0)rows.add(JSONObject(change.toString())) else rows[index]=JSONObject(change.toString())
   }
   return JSONArray(rows)
 }
 private fun activeHermesRuns(messages:JSONArray?):JSONArray=JSONArray((messages?.objects()?:emptyList())
  .filter{it.optString("role")=="user"&&it.optString("status") in setOf("queued","sending","running","unknown","approval_required")}
  .map{message->JSONObject().put("message_id",message.optString("id"))
   .put("run_id",message.opt("run_id")).put("status",message.optString("status"))
   .put("phase",message.optString("phase")).put("active_tool",message.opt("active_tool"))
   .put("received_at",message.opt("received_at"))})
 private fun reactionEvents(messages:List<JSONObject>):List<ReactionFeedback> = messages.mapNotNull{message->
   if(message.optString("role")!="user")return@mapNotNull null
   val reaction=message.optJSONObject("reaction")?:return@mapNotNull null
   val eventId=reaction.optString("event_id")
   val emoji=reaction.optString("emoji")
   if(eventId.isBlank()||emoji.isBlank())null else ReactionFeedback(message.optString("id"),eventId,emoji)
 }
 private fun applyHermesTasks(payload:JSONObject,snapshot:Boolean){
   val full=payload.optJSONArray("tasks")
   val changed=payload.array("changed_tasks")+listOfNotNull(payload.optJSONObject("task"))
   if(full==null&&changed.isEmpty())return
   taskLedger=if(full!=null)JSONObject().put("items",JSONArray(full.toString())) else
    JSONObject(taskLedger.toString()).put("items",mergeHermesRows(taskLedger.optJSONArray("items"),changed,"id"))
   if(snapshot||full!=null)taskLedgerFresh=true
   taskLedgerError=""
   runCatching{store.secureCache("personal-tasks.enc",taskLedger)}
 }
 private fun applyHermesEvent(kind:String,payload:JSONObject){
   if(kind=="snapshot"){
     if(payload.optJSONArray("messages")==null||payload.optJSONArray("runs")==null)return
     val snapshot=JSONObject(payload.toString())
     reactionFeedbackTracker.baseline(reactionEvents(snapshot.array("messages")))
     if(snapshot.optString("conversation_id").isBlank())snapshot.put("conversation_id",hermes.optString("conversation_id").ifBlank{"personal-main"})
     hermes=snapshot;hermesFresh=true;hermesError="";hermesStreaming=true
     applyHermesTasks(payload,true)
     reconcileHermesOutbox(snapshot.array("messages"))
     dispatchQueuedHermes()
     runCatching{store.secureCache("hermes-conversation.enc",snapshot)}
     return
   }
   if(kind!="update")return
   applyHermesTasks(payload,false)
   val current=JSONObject().apply{hermes.keys().forEach{key->put(key,hermes.opt(key))}}
   if(payload.has("revision")&&payload.optLong("revision")<=current.optLong("revision"))return
   val message=payload.optJSONObject("message")?:payload.optJSONObject("changed_message")
    ?:payload.takeIf{it.has("id")&&it.has("role")}
   val changedMessages=(payload.optJSONArray("messages")?.objects()?:emptyList())+listOfNotNull(message)
   if(reactionFeedbackTracker.live(reactionEvents(changedMessages))!=null&&active&&hermesVisible)hermesReactionSequence++
   val previousMessages=current.array("messages")
   val proposalChanged=changedMessages.any{change->
    val previous=previousMessages.firstOrNull{it.optString("id")==change.optString("id")}
    previous?.optString("active_tool")?.endsWith("propose_work")==true||change.optString("status")=="completed"
   }
   if(proposalChanged)viewModelScope.launch{refreshWorkProposals()}
   if(changedMessages.isNotEmpty()){
     current.put("messages",mergeHermesRows(current.optJSONArray("messages"),changedMessages,"id"))
     current.put("runs",activeHermesRuns(current.optJSONArray("messages")))
     reconcileHermesOutbox(changedMessages)
   }else payload.optJSONArray("runs")?.let{current.put("runs",JSONArray(it.toString()))}
   if(payload.has("revision"))current.put("revision",payload.optLong("revision"))
   if(current.optString("conversation_id").isBlank())current.put("conversation_id","personal-main")
   if(changedMessages.isNotEmpty()||payload.has("runs")||payload.has("run")||payload.has("changed_tasks")||payload.has("task")){
     hermes=current;hermesFresh=true;hermesError="";hermesStreaming=true
   }
   hermesReconcile?.cancel()
   if(payload.optJSONArray("messages")==null&&changedMessages.isEmpty())hermesReconcile=viewModelScope.launch{delay(700);refreshHermes()}
 }
 suspend fun refreshHermes(){
   if(hermesLoading)return
   hermesLoading=true
   try{
     val data=store.request("/personal/conversation")
     if(data.optString("conversation_id").isBlank()||data.optJSONArray("messages")==null||data.optJSONArray("runs")==null)error("Pi 对话数据格式不完整")
     if(data.has("revision")&&data.optLong("revision")<hermes.optLong("revision"))return
     reactionFeedbackTracker.baseline(reactionEvents(data.array("messages")))
     hermes=data;hermesFresh=true;hermesError=""
     applyHermesTasks(data,true)
     reconcileHermesOutbox(data.array("messages"))
     dispatchQueuedHermes()
     runCatching{store.secureCache("hermes-conversation.enc",data)}
   }catch(e:CancellationException){throw e}
    catch(e:Exception){hermesFresh=false;hermesError=e.message?:"Pi 暂时无法连接"}
   finally{hermesLoading=false}
 }
 fun sendHermes(requestId:String=UUID.randomUUID().toString()):String?{
   val message=hermesDraft.trim()
   if(message.isBlank()||store.token.isBlank())return null
   val rid=requestId
   val reference=hermesReference?.let{JSONObject(it.toString())}
   if(reference!=null&&!messageReferencesAvailable){hermesSendNote="当前服务尚未启用消息引用，草稿已保留。连接新版本后再发送。";return null}
   if(reference?.optString("mode")=="reply"&&outboxDependencyBlocked(reference.optString("id"),hermesOutbox)){
     hermesSendNote="这条补充依赖的消息尚未确认接收，请先核对原消息；其他独立消息仍可发送。";return null
   }
   if(hermesOutbox.any{it.id==rid})return null
   val entry=ConversationOutboxEntry(rid,message,reference,state=if(hermesFresh)"prepared" else "queued_local")
   hermesSending=true
   try{saveHermesOutbox(hermesOutbox+entry,clearDraft=true)}catch(e:Exception){hermesSendNote=e.message?:"发送状态保存失败，草稿已保留";return null}
   finally{hermesSending=false}
   recordOutgoing(entry.outgoing())
   hermesSendNote="";hermesError="";hermesDraft="";hermesReference=null
   if(hermesFresh)deliverHermes(entry) else hermesSendNote="已保存到手机，连接恢复后发送。"
   return rid
 }
 private fun saveHermesOutbox(entries:List<ConversationOutboxEntry>,clearDraft:Boolean=false){
   // Keep every uncertain entry; bound only acknowledged history.
   val keep=entries.filter{it.state!="accepted"}+entries.filter{it.state=="accepted"}.takeLast(64)
   val ordered=keep.sortedBy{it.createdAt}
   val values=mutableMapOf("hermes-outbox" to serializeConversationOutbox(ordered),"hermes-pending" to "")
   if(clearDraft)values["hermes-draft"]=""
   store.saveSecureTexts(values,durable=true)
   hermesOutbox=ordered
 }
 private fun settleHermesOutbox(id:String,state:String,serverId:String=""){
   val updated=hermesOutbox.map{if(it.id==id)it.copy(state=state,serverId=serverId.ifBlank{it.serverId}) else it}
   saveHermesOutbox(updated)
   updateOutgoing(id,if(state=="accepted")"sent" else if(state=="sending")"sending" else "unknown",serverId)
 }
 private fun reconcileHermesOutbox(messages:List<JSONObject>){
   val updated=reconcileConversationOutbox(hermesOutbox,messages)
   if(updated==hermesOutbox)return
   runCatching{saveHermesOutbox(updated)}.onFailure{hermesSendNote="回执已找到，本地记录保存失败；不会自动重发。"}
   updated.forEach{entry->if(entry.state=="accepted")updateOutgoing(entry.id,"sent",entry.serverId)}
 }
 private fun deliverHermes(entry:ConversationOutboxEntry){
   if(hermesSendJobs.containsKey(entry.id))return
   val rid=entry.id
   updateOutgoing(rid,"sending")
   hermesSendJobs[rid]=viewModelScope.launch(start=CoroutineStart.LAZY){
     try{
       settleHermesOutbox(rid,"sending")
       val receipt=store.request("/personal/conversation/messages",entry.body())
       if(!conversationReceiptConfirmed(receipt.optString("status"),receipt.optString("message_id"),receipt.optString("request_id"),rid))error("Pi 尚未确认接收这条消息")
       if(receipt.optString("request_id")!=rid)error("发送回执请求号不匹配")
       settleHermesOutbox(rid,"accepted",receipt.optString("message_id"))
       updateOutgoing(rid,if(receipt.optString("status") in setOf("failed","unknown"))receipt.optString("status") else "sent",receipt.optString("message_id"))
       hermesSendNote=if(receipt.optString("status") in listOf("failed","unknown"))"Pi 已接收，请查看这条消息的执行状态。" else "Pi 已接收"
       // Receipt releases the local send immediately. The snapshot is independent.
       viewModelScope.launch{refreshHermes()}
     }catch(e:CancellationException){
       runCatching{settleHermesOutbox(rid,"unknown")};throw e
     }catch(e:Exception){
       runCatching{settleHermesOutbox(rid,"unknown")}
       updateOutgoing(rid,"unknown")
       hermesSendNote="这条发送结果待核实，已保留在待核实列表；其他消息可继续发送。";hermesError=e.message?:"暂时无法发送"
     }finally{hermesSendJobs.remove(rid)}
   }
   hermesSendJobs[rid]?.start()
 }
 private fun dispatchQueuedHermes(){
   if(!hermesFresh||store.token.isBlank())return
   // These entries have never reached the network. Unknown entries are excluded.
   hermesOutbox.filter{it.state=="queued_local"}.forEach{deliverHermes(it)}
 }
 fun retryHermes(requestId:String){
   val entry=hermesOutbox.firstOrNull{it.id==requestId&&canRetryOutbox(it.state)}?:return
   if(!hermesFresh||store.token.isBlank())return
   hermesSendNote="正在核对同一请求号的接收状态"
   deliverHermes(entry)
 }
 private fun recordOutgoing(message:OutgoingMessage){
   outgoingMessages.add(message)
   while(outgoingMessages.count{it.scope==message.scope&&it.status=="sent"}>64)outgoingMessages.removeAt(outgoingMessages.indexOfFirst{it.scope==message.scope&&it.status=="sent"})
 }
 private fun updateOutgoing(id:String,status:String,serverId:String=""){
   val index=outgoingMessages.indexOfFirst{it.id==id}
   if(index>=0)outgoingMessages[index]=outgoingMessages[index].copy(status=status,serverId=serverId.ifBlank{outgoingMessages[index].serverId})
 }
 fun stopHermesRetry(requestId:String=hermesPending.optString("request_id")){
   runCatching{settleHermesOutbox(requestId,"abandoned")}
    .onSuccess{hermesSendNote="这条消息继续保留为待核实，不再显示重试操作。"}
    .onFailure{hermesSendNote="本地状态未保存，请稍后再试。"}
 }
 fun openTaskDetail(taskId:String,messageId:String=""){
  if(taskDetailId.isBlank())taskReturnPage=rootPage
  taskDetailId=taskId;taskReturnMessageId=messageId
  externalTaskRoute++
 }
 /** Opens the task list under a status filter; the chip row owns the same state. */
 fun openTaskList(filter:String){
  taskFilter=filter;taskDetailId="";taskReturnMessageId=""
  externalTaskRoute++
 }
 fun returnToHermes(messageId:String=taskReturnMessageId){
   hermesTargetMessageId=messageId;taskDetailId="";taskReturnMessageId="";externalHermesRoute++
 }
 override fun onCleared(){
   hermesVoiceTimer?.cancel();runCatching{hermesRecorder?.stop()};runCatching{hermesRecorder?.release()};hermesRecordingFile?.delete()
   super.onCleared()
 }
 suspend fun refreshPersonal(){
   if(personalLoading)return
   personalLoading=true
   try{
     val overview=store.request("/personal/overview")
     if(overview.optInt("schema_version")!=1)error("个人概览版本暂不支持")
     personal=overview;personalFresh=true;personalError=""
     runCatching{store.secureCache("personal-overview.enc",overview)}
   }catch(e:Exception){personalFresh=false;personalError=e.message?:"个人概览暂时无法连接"}
   finally{personalLoading=false}
 }
 fun followVoiceDelivery(workId:String){
  val id=runCatching{UUID.fromString(workId)}.getOrNull()?:return
  voiceWatch?.cancel();voiceDelivery="正在接收你的语音"
  voiceWatch=viewModelScope.launch{
   androidx.work.WorkManager.getInstance(getApplication()).getWorkInfoByIdFlow(id).collect{info->
    when(info?.state){
     androidx.work.WorkInfo.State.SUCCEEDED->{voiceDelivery="";info.outputData.getString("sid")?.let{openId(it);externalWorkRoute++};voiceWatch?.cancel()}
     androidx.work.WorkInfo.State.FAILED,androidx.work.WorkInfo.State.CANCELLED->{voiceDelivery="";error=info.outputData.getString("error")?:"语音尚未送达，可打开小窗重试。";voiceWatch?.cancel()}
     androidx.work.WorkInfo.State.ENQUEUED->voiceDelivery="录音已排队，联网后自动发送"
     androidx.work.WorkInfo.State.RUNNING->voiceDelivery=if(info.progress.getString("phase")=="sending")"正在进入这条 Pi 会话"else"正在把语音交给 Pi"
     else->Unit
    }
   }
  }
 }
 fun open(s:JSONObject){selected=s.getString("id");store.prefs.edit().putString("selected",selected).apply();val cached=store.cached(store.detailCache(selected));detail=if(cached.has("session"))cached else JSONObject().put("session",s);live=JSONObject();liveFresh=false;liveSessionId="";queryInSession=q;targetMessage=s.optJSONArray("matches")?.optString(0)?:"";val id=selected;viewModelScope.launch{refreshDetail(id)}}
 fun openId(id:String){open(JSONObject().put("id",id))}
 fun close(){selected="";archived=false;store.prefs.edit().remove("selected").apply();detail=JSONObject();live=JSONObject();liveFresh=false;liveSessionId=""}
 fun draft()=drafts.getOrPut(selected){store.prefs.getString("draft:$selected","")?:""}
 fun setDraft(value:String){drafts[selected]=value;store.savePrefSoon("draft:$selected",value)}
 private fun selectionKey(agentName:String,sid:String)=if(sid.isBlank())"new:$agentName" else "session:$sid"
 fun selection(agentName:String,sid:String=""):ModelSelection {
   val key=selectionKey(agentName,sid)
   return selections.getOrPut(key){
     val session=if(sid.isNotBlank()&&sid==selected)detail.optJSONObject("session") else null
     ModelSelection(store.prefs.getString("model:$key",session?.optString("model").orEmpty()).orEmpty(),store.prefs.getString("effort:$key",session?.optString("effort").orEmpty()).orEmpty())
   }
 }
 fun chooseModel(agentName:String,sid:String="",model:String,effort:String){
   val key=selectionKey(agentName,sid)
   selections[key]=ModelSelection(model,effort)
   store.prefs.edit().putString("model:$key",model).putString("effort:$key",effort).apply()
 }
 fun loadModels(agentName:String,force:Boolean=false){
   if(agentName !in listOf("pi","claude","codex") || catalogLoading[agentName]==true || !force&&catalogs.containsKey(agentName))return
   catalogLoading[agentName]=true
   viewModelScope.launch{
     try{
       val data=store.request("/models?agent=$agentName")
       catalogs[agentName]=data.array("models").mapNotNull{entry->
         val id=entry.optString("id");if(id.isBlank())null else ModelChoice(
           id,entry.optString("label",id).ifBlank{id},entry.optString("provider"),
           entry.optJSONArray("efforts")?.let{choices->(0 until choices.length()).mapNotNull{i->choices.optString(i).takeIf(String::isNotBlank)}}?:emptyList(),
           entry.optString("default_effort"),
         )
       }
       catalogErrors.remove(agentName)
     }catch(e:Exception){catalogErrors[agentName]=e.message?:"暂时无法读取模型列表"}
     finally{catalogLoading[agentName]=false}
   }
 }
 suspend fun refresh(){
   try{
    // A proven pre-submission refusal can release the old create request without replay.
    store.prefs.getString("pending:/sessions",null)?.let{rid->
     runCatching{store.request("/receipts/${enc(rid)}")}.getOrNull()?.let{receipt->
      if(receipt.optString("request_id")==rid&&receipt.optString("status")=="rejected"&&receipt.optString("submission_state")=="not_submitted"){
       if(store.prefs.edit().remove("pending:/sessions").remove("pending:/sessions:body").commit()){
        error=receipt.optString("error","上一条工作没有提交，草稿已保留，可以重新发送。")
       }
      }
     }
    }
    val health=store.request("/health")
    messageReferencesAvailable=health.optJSONObject("features")?.optBoolean("message_references_v1")==true
    val includeArchived=archived
    val all=store.request("/sessions?archived=$includeArchived")
    if(!includeArchived){store.cache("list.json",all);allRows=all.array("sessions")}
    allRowsFresh=!includeArchived&&active
    index=all.optJSONObject("index")?:JSONObject();connected=true
    val after=if(days>0)System.currentTimeMillis()/1000.0-days*86400 else 0.0
    rows=if(q.isBlank()&&agent.isBlank()&&role.isBlank()&&cwd.isBlank()&&days==0)all.array("sessions") else store.request("/sessions?q=${enc(q)}&agent=$agent&role=$role&cwd=${enc(cwd)}&after=$after&sort=$sort&archived=$archived").array("sessions")
    rows.filter{it.optBoolean("managed")}.forEach{store.notifyStatus(it.getString("id"),it.optString("status"),it.optString("display_title"))}
   }catch(e:Exception){messageReferencesAvailable=false;connected=false;allRowsFresh=false;liveFresh=false;rows=store.offline(q,agent,role,cwd,if(days>0)System.currentTimeMillis()/1000.0-days*86400 else 0.0)}
 }
 suspend fun refreshDetail(id:String){try{val d=store.request("/sessions/${enc(id)}");store.cache(store.detailCache(id),d);if(selected==id){
  val seed=detail.array("messages").firstOrNull{it.optString("id")=="accepted-first-message"}
  if(seed!=null&&d.array("messages").isEmpty())d.put("messages",JSONArray().put(seed))
  val session=d.optJSONObject("session")
  if(session!=null){
   val key=selectionKey(session.optString("agent"),id)
   val saved=selections[key]?:ModelSelection(store.prefs.getString("model:$key","").orEmpty(),store.prefs.getString("effort:$key","").orEmpty())
   if(!store.prefs.contains("model:$key")&&!store.prefs.contains("effort:$key") || saved.model.isBlank()&&saved.effort.isBlank()&&(session.optString("model").isNotBlank()||session.optString("effort").isNotBlank())){
    chooseModel(session.optString("agent"),id,session.optString("model"),session.optString("effort"))
   }
  }
  detail=d
 }}catch(_:Exception){}}
 fun run(action:suspend ()->Unit){viewModelScope.launch{busy=true;try{action()}catch(e:Exception){error=e.message?:"操作失败"}finally{busy=false}}}
 suspend fun mutation(path:String,body:JSONObject,requestId:String?=null,expectedSid:String?=null):JSONObject{
   val key="pending:$path";val existing=store.prefs.getString(key,null)
   if(existing!=null){
    val result=store.request("/receipts/${enc(existing)}")
    check(result.optString("request_id")==existing){"回执请求号不匹配，未重复发送"}
    if(result.optString("status")=="rejected"&&result.optString("submission_state")=="not_submitted"){
     check(store.prefs.edit().remove(key).remove("$key:body").commit()){"拒收回执保存失败，草稿已保留"}
     throw MessageNotSubmittedException(result.optString("error","消息尚未提交，草稿已保留"))
    }
    if(result.optString("status")=="accepted"){
     check(expectedSid==null||result.optString("sid")==expectedSid){"回执会话不匹配，结果待核实"}
     val same=store.prefs.getString("$key:body",null)==body.toString()
     check(store.prefs.edit().remove(key).remove("$key:body").commit()){"回执保存失败，结果待核实"}
     if(!same)error("上一条消息已送达。当前草稿已保留，请再次点击发送新内容。")
     return result
    }
    error("上次操作尚未确认。请查看会话或终端核实；请求号 $existing，未重复发送。")
   }
   val rid=requestId?:UUID.randomUUID().toString();check(store.prefs.edit().putString(key,rid).putString("$key:body",body.toString()).commit()){"请求号保存失败，草稿已保留"};body.put("request_id",rid)
   val result=store.request(path,body)
   check(result.optString("request_id")==rid){"回执请求号不匹配，未重复发送"}
   if(result.optString("status")=="rejected"&&result.optString("submission_state")=="not_submitted"){
    check(store.prefs.edit().remove(key).remove("$key:body").commit()){"拒收回执保存失败，草稿已保留"}
    throw MessageNotSubmittedException(result.optString("error","消息尚未提交，草稿已保留"))
   }
   check(expectedSid==null||result.optString("sid")==expectedSid){"回执会话不匹配，结果待核实"}
   if(result.optString("status")!="accepted")error("操作结果待核实，未重复发送")
   check(store.prefs.edit().remove(key).remove("$key:body").commit()){"回执保存失败，结果待核实"};return result
 }
 fun create(agentName:String,path:String,prompt:String,model:String,effort:String,requestId:String=UUID.randomUUID().toString()):String?{
   if(busy||!connected)return null
   val body=JSONObject().put("agent",agentName).put("cwd",path).put("prompt",prompt.trim()).put("model",model).put("effort",effort).put("sandbox","danger-full-access")
   if(store.prefs.getString("pending:/sessions",null)!=null&&store.prefs.getString("pending:/sessions:body",null)!=body.toString()){run{mutation("/sessions",body)};return null}
   val actualRid=store.prefs.getString("pending:/sessions",null)?:requestId
   val pending=OutgoingMessage(actualRid,"creating:$actualRid",prompt.trim())
   if(pending.text.isNotBlank())store.prefs.edit().putString("new-draft",pending.text).apply()
   creatingMessage=pending.takeIf{it.text.isNotBlank()};creatingAgent=agentName;busy=true
   viewModelScope.launch{
    try{
     store.prefs.edit().putString("lastAgent",agentName).putString("lastCwd",path).apply()
     val r=mutation("/sessions",body,actualRid)
     val sid=r.getString("sid")
     if(pending.text.isNotBlank())recordOutgoing(pending.copy(scope=sid,status="sent"))
     chooseModel(agentName,sid,model,effort)
     store.prefs.edit().remove("new-draft").apply();openId(sid)
     if(!detail.has("session")||detail.optJSONObject("session")?.has("agent")!=true){
      val session=JSONObject().put("id",selected).put("agent",agentName).put("cwd",path).put("display_title",pending.text.take(60)).put("status",if(pending.text.isBlank())"ready"else"submitted").put("managed",true).put("model",model).put("effort",effort).put("capabilities",JSONObject().put("input",true).put("terminal",agentName=="pi").put("resume",false))
      detail=JSONObject().put("session",session).put("messages",JSONArray())
     }
     refresh()
    }catch(e:Exception){error=e.message?:"创建结果待核实，草稿已保留"}
    finally{creatingMessage=null;busy=false}
   }
   return actualRid
 }
 fun send(requestId:String=UUID.randomUUID().toString()):String?{
   val id=selected;val text=draft().trim();if(text.isBlank()||busy||!connected)return null
   val agentName=detail.optJSONObject("session")?.optString("agent").orEmpty();val chosen=selection(agentName,id)
   val path="/sessions/${enc(id)}/input"
   val reference=workReferences[id]
   if(reference!=null&&!messageReferencesAvailable){error="当前服务尚未启用消息引用，草稿已保留。连接新版本后再发送。";return null}
   val body=JSONObject().put("text",text).put("model",chosen.model).put("effort",chosen.effort)
   reference?.let{body.put("reference",it)}
   val existing=store.prefs.getString("pending:$path",null)
   if(existing!=null&&store.prefs.getString("pending:$path:body",null)!=body.toString()){run{mutation(path,body,expectedSid=id);refreshDetail(id)};return null}
   val rid=existing?:requestId
   val prior=(detail.array("messages")+live.array("items")).map{it.optString("id")}.toSet()
   if(outgoingMessages.none{it.id==rid})recordOutgoing(OutgoingMessage(rid,id,text,reference,previousIds=prior)) else updateOutgoing(rid,"sending")
   drafts[id]="";store.prefs.edit().remove("draft:$id").apply();workReferences.remove(id);busy=true
   viewModelScope.launch{
    try{
     mutation(path,body,rid,id);updateOutgoing(rid,"sent");refreshDetail(id)
    }catch(e:Exception){
     updateOutgoing(rid,if(e is MessageNotSubmittedException)"failed"else"unknown")
     if(drafts[id].isNullOrBlank()){drafts[id]=text;store.prefs.edit().putString("draft:$id",text).apply();reference?.let{workReferences[id]=it}}
     error=e.message?:"发送结果待核实，未重复发送"
    }finally{busy=false}
   }
   return rid
 }
 fun resume()=run{val id=selected;val receipt=mutation("/sessions/${enc(id)}/resume",JSONObject());val resumed=receipt.optString("sid",id);if(resumed!=selected)openId(resumed);refreshDetail(resumed);refresh()}
 fun stop()=run{store.request("/sessions/${enc(selected)}/stop",JSONObject())}
 fun end()=run{store.request("/sessions/${enc(selected)}/end",JSONObject());refreshDetail(selected);refresh()}
 fun label(id:String,patch:JSONObject)=run{store.request("/sessions/${enc(id)}/labels",patch);refresh();if(id==selected)refreshDetail(id)}
}
