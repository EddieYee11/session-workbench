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
 * 语音记账投递，两步都是幂等的：
 * - transcribe：只转写，输出 transcript；音频转完即删。
 * - send：把记账消息发给 Hermes（request_id 去重），关掉小窗也不会取消已确认的发送。
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
  file.delete()
  return Result.success(workDataOf("transcript" to transcript.take(200)))
 }

 private suspend fun doSend(capture:String):Result{
  val store=Store(applicationContext)
  val text=inputData.getString("text")?.trim()?:return Result.failure()
  check(text.isNotBlank()){"记账内容为空"}
  val dir=File(applicationContext.filesDir,"quick-voice").apply{mkdirs()}
  val receipt=File(dir,"$capture.expense.json")
  if(receipt.exists())return Result.success(workDataOf("message_id" to JSONObject(receipt.readText()).optString("message_id")))
  setProgress(workDataOf("phase" to "sending"))
  // 与 Hermes 对话发送共用 request_id 去重语义：重放不会重复提交同一消息；这不是账本交易回执
  val result=store.request("/personal/conversation/messages",
   JSONObject().put("request_id","expense-$capture").put("text",text))
  val messageId=result.optString("message_id")
  check(messageId.isNotBlank()){"Hermes 尚未确认接收这条消息"}
  val tmp=File(dir,"$capture.expense.tmp")
  tmp.writeText(JSONObject().put("message_id",messageId).put("text",text).toString())
  check(tmp.renameTo(receipt))
  return Result.success(workDataOf("message_id" to messageId))
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
