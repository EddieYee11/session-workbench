package work.eddie.sessions

import android.content.Context
import androidx.work.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** Durable delivery: closing the small window does not cancel a submitted recording. */
class QuickVoiceDelivery(context:Context,params:WorkerParameters):CoroutineWorker(context,params){
 override suspend fun doWork():Result{
  val capture=inputData.getString("capture")?:return Result.failure()
  if(!capture.matches(Regex("[a-f0-9-]{36}")))return Result.failure()
  val store=Store(applicationContext)
  val dir=File(applicationContext.filesDir,"quick-voice")
  val file=File(dir,"$capture.m4a")
  val envelope=File(dir,"$capture.json")
  val receipt=File(dir,"$capture.accepted.json")
  return try{
   // WorkManager may replay after process death between server acceptance and its DB commit.
   if(receipt.exists()){
    val accepted=JSONObject(receipt.readText())
    return Result.success(workDataOf("sid" to accepted.getString("sid"),"reply_after" to accepted.optLong("reply_after",0L)))
   }
   setProgress(workDataOf("phase" to "transcribing"))
   // Persist the exact request before sending. A retry uses the same server receipt.
   val target=inputData.getString("sid").orEmpty()
   require(target.isBlank()||target.startsWith("pi:")){"快捷语音只发送给 Pi。"}
   val path=if(target.isBlank())"/sessions" else "/sessions/${URLEncoder.encode(target,"UTF-8")}/input"
   val packet=if(envelope.exists())JSONObject(envelope.readText()) else{
    val transcript=uploadVoice(store,file,capture).getString("text").trim()
    check(transcript.isNotBlank()){"没有听清，录音已保留，请再试一次。"}
    // Fix the old-turn boundary before sending. A retry must keep this boundary and request ID.
    val after=if(target.isBlank())0L else{
     val live=store.request("/sessions/${URLEncoder.encode(target,"UTF-8")}/live")
     val detail=store.request("/sessions/${URLEncoder.encode(target,"UTF-8")}")
     (live.array("items")+detail.array("messages")).maxOfOrNull{it.optString("id").removePrefix("pi:").toLongOrNull()?:0L}?:0L
    }
    val body=JSONObject().put("request_id","voice-$capture")
    if(target.isBlank())body.put("agent","pi").put("cwd",inputData.getString("cwd")?:"/Users/eddiegao/AI_Work_System")
     .put("prompt",transcript).put("model","").put("effort","").put("sandbox","danger-full-access")
    else body.put("text",transcript)
    JSONObject().put("path",path).put("body",body).put("reply_after",after).also{
     val temporary=File(dir,"$capture.tmp");temporary.writeText(it.toString());check(temporary.renameTo(envelope))
    }
   }
   // Accept the previous app version's saved envelope as well.
   val body=packet.optJSONObject("body")?:packet
   setProgress(workDataOf("phase" to "sending"))
   val result=store.request(packet.optString("path",path),body)
   check(result.optString("status")=="accepted"){"发送结果待确认；录音已保留，重试会核对同一条会话。"}
   val sid=result.getString("sid")
   val completed=JSONObject().put("sid",sid).put("reply_after",packet.optLong("reply_after",0L))
   val receiptTemp=File(dir,"$capture.accepted.tmp")
   receiptTemp.writeText(completed.toString());check(receiptTemp.renameTo(receipt))
   // Keep the tiny accepted receipt across worker retries; audio can now be safely removed.
   file.delete();envelope.delete()
   if(store.prefs.getString("quick-voice-file",null)==file.name)store.prefs.edit().remove("quick-voice-file").remove("quick-voice-capture-sid").apply()
   Result.success(workDataOf("sid" to sid,"reply_after" to packet.optLong("reply_after",0L)))
  }catch(e:java.util.concurrent.CancellationException){throw e}
   catch(e:Exception){Result.failure(workDataOf("error" to (e.message?:"暂未送达，录音已保留，可重试。").take(500)))}
 }
}

internal suspend fun uploadVoice(store:Store,file:File,capture:String):JSONObject=withContext(Dispatchers.IO){
 require(store.base.startsWith("https://")){"请先在 Com! 中完成配对。"}
 check(file.exists()&&file.length() in 128..5L*1024*1024){"录音文件不可用，请重新录制。"}
 val connection=URL(store.base+"/voice/transcribe/"+capture).openConnection() as HttpURLConnection
 connection.connectTimeout=12000;connection.readTimeout=100000;connection.instanceFollowRedirects=false
 connection.requestMethod="POST";connection.doOutput=true
 connection.setRequestProperty("Authorization","Bearer "+store.token)
 connection.setRequestProperty("Content-Type","audio/mp4");connection.setFixedLengthStreamingMode(file.length())
 try{
  connection.outputStream.use{output->file.inputStream().use{it.copyTo(output)}}
  val code=connection.responseCode
  val raw=(if(code in 200..299)connection.inputStream else connection.errorStream)?.bufferedReader()?.use{it.readText()}?:"{}"
  val result=runCatching{JSONObject(raw)}.getOrDefault(JSONObject())
  check(code in 200..299){result.optString("detail","上传失败：$code，录音已保留。")};result
 }finally{connection.disconnect()}
}
