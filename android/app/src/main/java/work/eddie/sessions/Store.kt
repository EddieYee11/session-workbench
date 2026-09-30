package work.eddie.sessions

import android.app.*
import android.content.*
import android.security.keystore.*
import android.util.Base64
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
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
fun statusLabel(s:String)=when(s){"running"->"运行中";"waiting"->"需要你回应";"completed"->"本轮完成";"interrupted"->"已中断";"ended"->"会话已结束";"failed"->"执行失败";"ready"->"可以开始";else->"历史记录"}

class Store(val context:Context) {
 val prefs=context.getSharedPreferences("workbench",0)
 private val dir=File(context.filesDir,"cache").apply{mkdirs()}
 var base:String
   get()=prefs.getString("base","")?:""
   set(v){require(v.startsWith("https://"));prefs.edit().putString("base",v.trimEnd('/')).apply()}
 private fun key():javax.crypto.SecretKey {
   val ks=KeyStore.getInstance("AndroidKeyStore").apply{load(null)}
   (ks.getKey("session-token",null) as? javax.crypto.SecretKey)?.let{return it}
   return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply{init(KeyGenParameterSpec.Builder("session-token",KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())}.generateKey()
 }
 var token:String
   get()=runCatching { val raw=Base64.decode(prefs.getString("token","")?:"",Base64.NO_WRAP);val c=Cipher.getInstance("AES/GCM/NoPadding");c.init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,raw.copyOfRange(0,12)));String(c.doFinal(raw.copyOfRange(12,raw.size))) }.getOrDefault("")
   set(v){val c=Cipher.getInstance("AES/GCM/NoPadding");c.init(Cipher.ENCRYPT_MODE,key());prefs.edit().putString("token",Base64.encodeToString(c.iv+c.doFinal(v.toByteArray()),Base64.NO_WRAP)).apply()}
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
 var rows by mutableStateOf(store.cached("list.json").array("sessions"))
 var selected by mutableStateOf(store.prefs.getString("selected","")?:"")
 var detail by mutableStateOf(if(selected.isNotEmpty())store.cached(store.detailCache(selected)) else JSONObject())
 var live by mutableStateOf(JSONObject())
 var error by mutableStateOf("")
 var connected by mutableStateOf(false)
 var busy by mutableStateOf(false)
 var index by mutableStateOf(JSONObject())
 var q by mutableStateOf(store.prefs.getString("search","")?:"");var agent by mutableStateOf("");var role by mutableStateOf("");var cwd by mutableStateOf("");var days by mutableIntStateOf(0);var sort by mutableStateOf("relevance")
 var working by mutableStateOf(true);var archived by mutableStateOf(false)
 var queryInSession by mutableStateOf(store.prefs.getString("session-search","")?:"");var targetMessage by mutableStateOf("")
 val drafts=mutableStateMapOf<String,String>()
 var active by mutableStateOf(true)
 var font by mutableFloatStateOf(store.prefs.getFloat("font",16f))
 init {viewModelScope.launch{snapshotFlow{q to queryInSession}.collect{(global,local)->store.prefs.edit().putString("search",global).putString("session-search",local).apply()}};viewModelScope.launch{var tick=0;while(true){if(active&&store.token.isNotEmpty()){
   if(tick%5==0)refresh()
   val id=selected
   if(id.isNotEmpty()){
    try{val l=store.request("/sessions/${enc(id)}/live");if(selected==id)live=l}catch(_:Exception){}
    if(tick%5==0)refreshDetail(id)
   }
   tick++
 };delay(800)}}}
 fun enc(s:String)=URLEncoder.encode(s,"UTF-8")
 fun open(s:JSONObject){selected=s.getString("id");store.prefs.edit().putString("selected",selected).apply();detail=store.cached(store.detailCache(selected));live=JSONObject();queryInSession=q;targetMessage=s.optJSONArray("matches")?.optString(0)?:"";viewModelScope.launch{refreshDetail(selected)}}
 fun openId(id:String){open(JSONObject().put("id",id))}
 fun close(){selected="";store.prefs.edit().remove("selected").apply();detail=JSONObject();live=JSONObject()}
 fun draft()=drafts.getOrPut(selected){store.prefs.getString("draft:$selected","")?:""}
 fun setDraft(value:String){drafts[selected]=value;store.prefs.edit().putString("draft:$selected",value).apply()}
 suspend fun refresh(){
   try{
    val all=store.request("/sessions?archived=$archived")
    if(!archived)store.cache("list.json",all)
    index=all.optJSONObject("index")?:JSONObject();connected=true
    val after=if(days>0)System.currentTimeMillis()/1000.0-days*86400 else 0.0
    rows=if(q.isBlank()&&agent.isBlank()&&role.isBlank()&&cwd.isBlank()&&days==0)all.array("sessions") else store.request("/sessions?q=${enc(q)}&agent=$agent&role=$role&cwd=${enc(cwd)}&after=$after&sort=$sort&archived=$archived").array("sessions")
    rows.filter{it.optBoolean("managed")}.forEach{store.notifyStatus(it.getString("id"),it.optString("status"),it.optString("display_title"))}
   }catch(e:Exception){connected=false;rows=store.offline(q,agent,role,cwd,if(days>0)System.currentTimeMillis()/1000.0-days*86400 else 0.0)}
 }
 suspend fun refreshDetail(id:String){try{val d=store.request("/sessions/${enc(id)}");store.cache(store.detailCache(id),d);if(selected==id)detail=d}catch(_:Exception){}}
 fun run(action:suspend ()->Unit){viewModelScope.launch{busy=true;try{action()}catch(e:Exception){error=e.message?:"操作失败"}finally{busy=false}}}
 suspend fun mutation(path:String,body:JSONObject):JSONObject{
   val key="pending:$path";val existing=store.prefs.getString(key,null)
   if(existing!=null){
    val result=store.request("/receipts/${enc(existing)}")
    if(result.optString("status")=="accepted"){
     val same=store.prefs.getString("$key:body",null)==body.toString()
     store.prefs.edit().remove(key).remove("$key:body").apply()
     if(!same)error("上一条消息已送达。当前草稿已保留，请再次点击发送新内容。")
     return result
    }
    error("上次操作尚未确认。请查看会话或终端核实；请求号 $existing，未重复发送。")
   }
   val rid=UUID.randomUUID().toString();store.prefs.edit().putString(key,rid).putString("$key:body",body.toString()).apply();body.put("request_id",rid)
   val result=store.request(path,body)
   if(result.optString("status")!="accepted")error("操作结果待核实，未重复发送")
   store.prefs.edit().remove(key).remove("$key:body").apply();return result
 }
 fun create(agentName:String,path:String,prompt:String,model:String,effort:String,sandbox:String)=run{
   store.prefs.edit().putString("lastAgent",agentName).putString("lastCwd",path).apply()
   val r=mutation("/sessions",JSONObject().put("agent",agentName).put("cwd",path).put("prompt",prompt).put("model",model).put("effort",effort).put("sandbox",sandbox))
   store.prefs.edit().remove("new-draft").apply();openId(r.getString("sid"));refresh()
 }
 fun send(){val id=selected;val text=draft();if(text.isBlank())return;run{
   mutation("/sessions/${enc(id)}/input",JSONObject().put("text",text))
   if(drafts[id]==text){drafts[id]="";store.prefs.edit().remove("draft:$id").apply()};refreshDetail(id)
 }}
 fun resume()=run{val id=selected;mutation("/sessions/${enc(id)}/resume",JSONObject());refreshDetail(id)}
 fun stop()=run{store.request("/sessions/${enc(selected)}/stop",JSONObject())}
 fun end()=run{store.request("/sessions/${enc(selected)}/end",JSONObject());refreshDetail(selected);refresh()}
 fun label(id:String,patch:JSONObject)=run{store.request("/sessions/${enc(id)}/labels",patch);refresh();if(id==selected)refreshDetail(id)}
}
