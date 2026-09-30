package work.eddie.sessions
import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
class StatusWorker(context:Context,params:WorkerParameters):CoroutineWorker(context,params){
 override suspend fun doWork():Result {
  val store=Store(applicationContext)
  if(store.token.isBlank()||!store.prefs.getBoolean("notifications",true))return Result.success()
  return try{val data=store.request("/sessions");store.cache("list.json",data);data.array("sessions").filter{it.optBoolean("managed")}.forEach{store.notifyStatus(it.getString("id"),it.optString("status"),it.optString("display_title"))};Result.success()}catch(_:Exception){Result.retry()}
 }
}
