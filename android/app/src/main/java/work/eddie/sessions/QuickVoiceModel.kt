package work.eddie.sessions

import android.app.Application
import android.media.MediaRecorder
import android.os.SystemClock
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.work.*
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.File
import java.net.URLEncoder
import java.util.UUID
import kotlin.math.ln

/** Foreground capture, followed by durable background delivery directly to Pi. */
class QuickVoiceModel(app: Application) : AndroidViewModel(app) {
    private val store = Store(app)
    private val prefs = store.prefs
    private val captureDir = File(app.filesDir, "quick-voice").apply { mkdirs() }
    var phase by mutableStateOf("ready"); private set
    var message by mutableStateOf(""); private set
    var seconds by mutableIntStateOf(0); private set
    var levels by mutableStateOf(List(24) { 0f }); private set
    var sessionId by mutableStateOf(prefs.getString("quick-voice-capture-sid", "") ?: ""); private set
    var replyText by mutableStateOf(""); private set
    var hasPendingSend by mutableStateOf(prefs.contains("quick-voice-pending")); private set
    var hasRecording by mutableStateOf(captureFile()?.exists() == true); private set
    val cwd: String get() = prefs.getString("lastCwd", "/Users/eddiegao/AI_Work_System") ?: "/Users/eddiegao/AI_Work_System"
    val paired: Boolean get() = store.base.isNotBlank() && store.token.isNotBlank()
    var deliveryId by mutableStateOf(prefs.getString("quick-voice-work", "") ?: ""); private set
    var restored by mutableStateOf(false); private set
    private var deliveryWatch: Job? = null
    private var replyWatch: Job? = null
    private var sessionEnded = false
    init {
        viewModelScope.launch {
            val previous=runCatching{UUID.fromString(deliveryId)}.getOrNull()
            if(previous!=null){
                val info=withContext(Dispatchers.IO){WorkManager.getInstance(getApplication()).getWorkInfoById(previous).get()}
                if(info?.state==WorkInfo.State.SUCCEEDED && prefs.getBoolean("quick-voice-read:$deliveryId",false)){deliveryId="";prefs.edit().remove("quick-voice-work").apply();hasRecording=false;sessionId=""}
                else watchDelivery(deliveryId)
            }
            restored=true
        }
    }
    private var recorder: MediaRecorder? = null
    private var recordingFile: File? = null
    private var timer: Job? = null
    private var started = 0L
    private var foreground = false
    private fun captureFile(): File? = prefs.getString("quick-voice-file", null)?.let { name ->
        File(captureDir, File(name).name).takeIf { it.extension == "m4a" }
    }
    fun permissionDenied() { message = "麦克风权限未开启。请在系统设置中允许 Com! 使用麦克风。" }
    fun onForeground() { foreground = true }
    fun onBackground() {
        foreground = false
        if (phase == "reply" && deliveryId.isNotBlank()) prefs.edit().putBoolean("quick-voice-read:$deliveryId",true).apply()
        if (phase == "recording") finishRecording(transcribe = false)
    }
    @Suppress("DEPRECATION")
    fun record() {
        if (!foreground || phase in listOf("recording", "transcribing", "sending", "queued", "waiting") || hasPendingSend) return
        if (!paired) { message = "先在 Com! 中完成 Mac mini 配对，再使用语音。"; return }
        replyWatch?.cancel(); replyText=""
        if(sessionEnded){sessionId="";sessionEnded=false}
        deliveryId=""; prefs.edit().remove("quick-voice-work").apply()
        val file = File(captureDir, UUID.randomUUID().toString() + ".m4a")
        try {
            val r = MediaRecorder()
            recorder = r
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioSamplingRate(16000)
            r.setAudioEncodingBitRate(64000)
            r.setOutputFile(file.absolutePath)
            r.prepare(); r.start()
            recordingFile = file
            started = SystemClock.elapsedRealtime(); seconds = 0
            levels = List(24) { 0f }; phase = "recording"; message = ""
            val endpoint = SpeechEndpointDetector()
            timer = viewModelScope.launch {
                while (phase == "recording") {
                    delay(50)
                    val amplitude = runCatching { r.maxAmplitude }.getOrDefault(0)
                    levels = levels.drop(1) + ((ln(1.0 + amplitude) / ln(32768.0)).toFloat().coerceIn(0f, 1f))
                    seconds = ((SystemClock.elapsedRealtime() - started) / 1000).toInt()
                    if (endpoint.sample(amplitude,SystemClock.elapsedRealtime())) finishRecording()
                    else if (seconds >= 60) {
                        if(endpoint.heardSpeech)finishRecording() else { cancelRecording(); message="没有检测到说话，未发送录音。轻点下方再说一句。" }
                    }
                }
            }
        } catch (_: Exception) {
            releaseRecorder(); file.delete(); phase = "ready"
            message = "暂时无法使用麦克风，请检查权限或其他应用的录音占用。"
        }
    }
    fun finishRecording(transcribe: Boolean = true) {
        if (phase != "recording") return
        timer?.cancel(); timer = null
        val file = recordingFile
        val stopped = runCatching { recorder?.stop() }.isSuccess
        releaseRecorder()
        phase = "ready"
        if (!stopped || file == null || file.length() < 512 || SystemClock.elapsedRealtime() - started < 650) {
            file?.delete(); message = "录音太短，请再说一次。原来的草稿已保留。"; return
        }
        // Replace the previous capture only after a complete, usable recording exists.
        captureFile()?.takeIf { it != file }?.delete()
        prefs.edit().putString("quick-voice-file", file.name).putString("quick-voice-capture-sid",sessionId).apply()
        hasRecording = true
        if (transcribe) transcribe() else message = "录音已保存，下次打开可继续发送。"
    }
    fun cancelRecording() {
        if (phase != "recording") return
        timer?.cancel(); timer = null
        runCatching { recorder?.stop() }; releaseRecorder()
        recordingFile?.delete(); recordingFile = null
        phase = "ready"; message = "本次录音已取消，原来的草稿保留。"
    }
    fun transcribe() {
        val file=captureFile()?:return
        if(phase !in listOf("ready","failed"))return
        val request=OneTimeWorkRequestBuilder<QuickVoiceDelivery>()
            .setInputData(workDataOf("capture" to file.nameWithoutExtension,"cwd" to cwd,"sid" to (prefs.getString("quick-voice-capture-sid",sessionId)?:sessionId)))
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build()
        deliveryId=request.id.toString()
        prefs.edit().putString("quick-voice-work",deliveryId).commit()
        phase="queued";message=""
        WorkManager.getInstance(getApplication()).enqueueUniqueWork("voice-"+file.nameWithoutExtension,ExistingWorkPolicy.KEEP,request)
        watchDelivery(deliveryId)
    }
    private fun watchDelivery(id:String){
        val uuid=runCatching{UUID.fromString(id)}.getOrNull()?:return
        deliveryWatch?.cancel()
        deliveryWatch=viewModelScope.launch {
            WorkManager.getInstance(getApplication()).getWorkInfoByIdFlow(uuid).collect { info->
                when(info?.state){
                    WorkInfo.State.ENQUEUED,WorkInfo.State.BLOCKED->{phase="queued";message="已排队，网络恢复后自动交给 Pi。"}
                    WorkInfo.State.RUNNING->{phase=info.progress.getString("phase")?:"transcribing";message=""}
                    WorkInfo.State.SUCCEEDED->{
                        sessionId=info.outputData.getString("sid")?:"";hasRecording=false;message=""
                        phase="waiting"; watchReply(sessionId,info.outputData.getLong("reply_after",0L))
                        deliveryWatch?.cancel()
                    }
                    WorkInfo.State.FAILED,WorkInfo.State.CANCELLED->{phase="ready";hasRecording=captureFile()?.exists()==true;message=info.outputData.getString("error")?:"尚未送达，录音已保留。";deliveryWatch?.cancel()}
                    else->Unit
                }
            }
        }
    }
    private fun watchReply(sid:String,after:Long){
        replyWatch?.cancel()
        replyWatch=viewModelScope.launch {
            var observedRunning=false
            var tick=0
            val began=SystemClock.elapsedRealtime()
            while(isActive){
                if(!foreground){delay(400);continue}
                try{
                    val live=store.request("/sessions/${URLEncoder.encode(sid,"UTF-8")}/live")
                    val status=live.optString("status")
                    observedRunning=observedRunning||status=="running"
                    var items=live.array("items")
                    // Finished messages can outlive the live event log. Read history without resuming Pi.
                    if(tick%4==0||status in listOf("completed","ended","failed")){
                        val detail=store.request("/sessions/${URLEncoder.encode(sid,"UTF-8")}")
                        items=(items+detail.array("messages")).distinctBy{it.optString("id")}
                    }
                    val current=items.filter{(it.optString("id").removePrefix("pi:").toLongOrNull()?:0L)>after}
                    replyText=voiceReplyText(items.map{VoiceReplyItem(it.optString("id"),it.optString("role"),it.optString("text"))},after)
                    message=""
                    if(voiceReplyFinished(status,replyText.isNotBlank(),observedRunning,current.isNotEmpty(),SystemClock.elapsedRealtime()-began)){
                        sessionEnded=status=="ended"
                        phase="reply"
                        if(replyText.isBlank())message=if(status=="completed")"Pi 已处理完这句话，本轮没有文字回复。"else"这轮对话已结束，暂时没有回复。"
                        break
                    }
                    if(status=="waiting")message="Pi 需要进一步确认，可以上滑展开处理。"
                }catch(e:CancellationException){throw e}
                 catch(_:Exception){message="正在重新连接 Pi，回复会继续显示在这里。"}
                tick++;delay(650)
            }
        }
    }
    private fun releaseRecorder() { runCatching { recorder?.release() }; recorder = null }
    override fun onCleared() { replyWatch?.cancel(); deliveryWatch?.cancel(); timer?.cancel(); runCatching { recorder?.stop() }; releaseRecorder(); super.onCleared() }
}
