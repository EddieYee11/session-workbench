package work.eddie.sessions

import android.content.Context
import androidx.work.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * 快速语音及记账共用的幂等投递链：
 * - transcribe：只转写，输出 transcript；音频转完即删。
 * - send：持久受理后交给原生 Pi（request_id 去重），关掉小窗也不会取消已确认的发送。
 */
class QuickVoiceDelivery(context:Context,params:WorkerParameters):CoroutineWorker(context,params){
 override suspend fun doWork():Result{
  val step=inputData.getString("step")?:"transcribe"
  val capture=inputData.getString("capture")?:return Result.failure()
  if(!capture.matches(Regex("[a-f0-9-]{36}")))return Result.failure()
  return try{
   when(step){
    "send"->doSend(capture)
    else->doTranscribe(capture)
   }
  }catch(e:java.util.concurrent.CancellationException){throw e}
   catch(e:Exception){Result.failure(workDataOf("error" to (e.message?:"暂未送达，录音已保留。").take(300)))}
 }

 private suspend fun doTranscribe(capture:String):Result{
  val store=Store(applicationContext)
  val file=File(applicationContext.filesDir,"quick-voice/$capture.m4a")
  setProgress(workDataOf("phase" to "transcribing"))
  val transcript=uploadVoice(store,file,capture).getString("text").trim()
  check(transcript.isNotBlank()){"没有听清，请再说一次。"}
  val conversation=inputData.getBoolean("conversation",false)
  check(!conversation||transcript.length<=2000){"这段语音较长，请分两次说，录音已保留。"}
  file.delete()
  // WorkManager Data is bounded; 2000 Chinese characters fit its 10 KiB limit.
  return Result.success(workDataOf("transcript" to if(conversation)transcript else transcript.take(200)))
 }

 private suspend fun doSend(capture:String):Result{
  val store=Store(applicationContext)
  val text=inputData.getString("text")?.trim()?:return Result.failure()
  check(text.isNotBlank()){"语音内容为空"}
  val conversation=inputData.getBoolean("conversation",false)
  val purpose=if(conversation)"quickvoice"else"expense"
  val dir=File(applicationContext.filesDir,"quick-voice").apply{mkdirs()}
  val receipt=File(dir,"$capture.$purpose.json")
  val requestId="$purpose-$capture"
  if(receipt.exists()){
   val saved=JSONObject(receipt.readText())
   // A receipt issued by a previous Hermes build is not permission to replay it
   // through another agent after an app update.
   check(saved.optString("agent")=="pi"){"这条语音旧版已交给 Hermes，请先核实结果，不会再次交给派。"}
   validateReceipt(saved,requestId,text)
   return accepted(saved)
  }
  setProgress(workDataOf("phase" to "sending"))
  // A queue receipt confirms durable handoff, never a completed bookkeeping write.
  val result=store.request("/personal/quick-voice/messages",
   JSONObject().put("request_id",requestId).put("text",text)
    .put("purpose",if(conversation)"conversation"else"expense"))
  validateReceipt(result,requestId,text)
  val tmp=File(dir,"$capture.$purpose.tmp")
  tmp.writeText(result.toString())
  check(tmp.renameTo(receipt))
  return accepted(result)
 }

 private fun validateReceipt(receipt:JSONObject,requestId:String,text:String){
  check(receipt.optString("request_id")==requestId&&receipt.optString("agent")=="pi"&&receipt.optString("text")==text){"派的受理回执不匹配，请重试同一条消息核实。"}
  check(receipt.optString("message_id").isNotBlank()){"派尚未确认受理这条消息。"}
  val status=receipt.optString("status")
  check(piVoiceAccepted(status)){receipt.optString("error").ifBlank{"派的投递结果待核实，可重试同一条消息查看；不会重复交办。"}}
 }

 private fun accepted(receipt:JSONObject)=Result.success(workDataOf(
  "message_id" to receipt.optString("message_id"),"request_id" to receipt.optString("request_id"),
  "status" to receipt.optString("status"),"session_id" to receipt.optString("session_id")))
}

internal fun piVoiceAccepted(status:String)=status in setOf("accepted","starting","sending","submitted","running","executing","responding","completed")

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
