package work.eddie.sessions

import android.app.Application
import android.media.MediaRecorder
import android.os.SystemClock
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.work.*
import kotlinx.coroutines.*
import java.io.File
import java.util.UUID
import kotlin.math.ln

/**
 * 悬浮语音记账：录音 → 转写 → 解析 → 3 秒后自动记账，说完就走。
 * phase: ready | recording | transcribing | confirm | sending | sent
 */
class QuickVoiceModel(app: Application) : AndroidViewModel(app) {
 private val store = Store(app)
 private val prefs = store.prefs
 private val captureDir = File(app.filesDir, "quick-voice").apply { mkdirs() }
 var phase by mutableStateOf("ready"); private set
 var message by mutableStateOf(""); private set
 var seconds by mutableIntStateOf(0); private set
 var levels by mutableStateOf(List(24) { 0f }); private set
 var transcript by mutableStateOf(""); private set
 var expense by mutableStateOf<ParsedExpense?>(null); private set
 val paired: Boolean get() = store.base.isNotBlank() && store.token.isNotBlank()
 var restored by mutableStateOf(false); private set
 var openRecordingRequest by mutableIntStateOf(0); private set
 private var consumedOpenRecordingRequest = 0
 private var pendingCapture: String? = null
 private var transcribeWatch: Job? = null
 private var sendWatch: Job? = null
 private var recorder: MediaRecorder? = null
 private var recordingFile: File? = null
 private var timer: Job? = null
 private var started = 0L
 var isForeground by mutableStateOf(false); private set

 init { restored = true }

 private fun captureFile(): File? = prefs.getString("quick-voice-file", null)?.let { name ->
  File(captureDir, File(name).name).takeIf { it.extension == "m4a" }
 }

 fun requestRecordingOnOpen() { openRecordingRequest++ }
 fun consumeRecordingOnOpen(): Boolean {
  if (openRecordingRequest == consumedOpenRecordingRequest) return false
  consumedOpenRecordingRequest = openRecordingRequest
  if (phase == "recording") return false
  transcribeWatch?.cancel(); sendWatch?.cancel()
  phase = "ready"; message = ""; transcript = ""; expense = null
  return true
 }
 fun permissionDenied() { message = "麦克风权限未开启。请在系统设置中允许 Com! 使用麦克风。" }
 fun onForeground() { isForeground = true }
 fun onBackground() {
  isForeground = false
  if (phase == "recording") finishRecording(transcribe = false)
 }

 @Suppress("DEPRECATION")
 fun record() {
  if (!isForeground || phase in listOf("recording", "transcribing", "confirm", "sending", "sent")) return
  if (!paired) { message = "先在 Com! 中完成 Mac mini 配对，再使用语音记账。"; return }
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
   levels = List(24) { 0f }; phase = "recording"; message = ""; transcript = ""; expense = null
   val endpoint = SpeechEndpointDetector()
   timer = viewModelScope.launch {
    while (phase == "recording") {
     delay(50)
     val amplitude = runCatching { r.maxAmplitude }.getOrDefault(0)
     levels = levels.drop(1) + ((ln(1.0 + amplitude) / ln(32768.0)).toFloat().coerceIn(0f, 1f))
     seconds = ((SystemClock.elapsedRealtime() - started) / 1000).toInt()
     if (endpoint.sample(amplitude, SystemClock.elapsedRealtime())) finishRecording()
     else if (seconds >= 60) {
      if (endpoint.heardSpeech) finishRecording() else { cancelRecording(); message = "没有检测到说话，未记账。点“重说”再来一次。" }
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
   file?.delete(); message = "录音太短，请再说一次。"; return
  }
  captureFile()?.takeIf { it != file }?.delete()
  prefs.edit().putString("quick-voice-file", file.name).apply()
  if (transcribe) transcribe() else message = "录音已保存，下次打开可继续识别。"
 }

 fun cancelRecording() {
  if (phase != "recording") return
  timer?.cancel(); timer = null
  runCatching { recorder?.stop() }; releaseRecorder()
  recordingFile?.delete(); recordingFile = null
  phase = "ready"; message = "本次录音已取消。"
 }

 /** 重说：取消转写，回到可录音状态 */
 fun retry() {
  pendingCapture?.let { WorkManager.getInstance(getApplication()).cancelUniqueWork("voice-$it") }
  transcribeWatch?.cancel()
  transcript = ""; expense = null; message = ""; phase = "ready"
 }

 /** 关窗时调用：转写中可取消；已确认的发送继续在后台完成 */
 fun cancelPending() {
  if (phase == "transcribing" || phase == "confirm") {
   pendingCapture?.let { WorkManager.getInstance(getApplication()).cancelUniqueWork("voice-$it") }
   transcribeWatch?.cancel()
  }
  if (phase == "recording") finishRecording(transcribe = false)
 }

 fun transcribe() {
  val file = recordingFile ?: captureFile() ?: return
  if (phase !in listOf("ready", "failed")) return
  val capture = file.nameWithoutExtension
  pendingCapture = capture
  val request = OneTimeWorkRequestBuilder<QuickVoiceDelivery>()
   .setInputData(workDataOf("step" to "transcribe", "capture" to capture))
   .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build()
  phase = "transcribing"; message = ""
  WorkManager.getInstance(getApplication()).enqueueUniqueWork("voice-$capture", ExistingWorkPolicy.KEEP, request)
  watchTranscribe(request.id)
 }

 private fun watchTranscribe(id: UUID) {
  transcribeWatch?.cancel()
  transcribeWatch = viewModelScope.launch {
   WorkManager.getInstance(getApplication()).getWorkInfoByIdFlow(id).collect { info ->
    when (info?.state) {
     WorkInfo.State.RUNNING -> { phase = "transcribing" }
     WorkInfo.State.SUCCEEDED -> {
      transcript = info.outputData.getString("transcript").orEmpty()
      expense = parseExpense(transcript)
      phase = "confirm"; message = ""
      transcribeWatch?.cancel()
     }
     WorkInfo.State.FAILED, WorkInfo.State.CANCELLED -> {
      phase = "ready"; message = info.outputData.getString("error") ?: "没听清，请再说一次。"
      transcribeWatch?.cancel()
     }
     else -> Unit
    }
   }
  }
 }

 /** 确认记账（3 秒倒计时后自动调用，或点“立即记账”） */
 fun confirmExpense() {
  val e = expense ?: return
  if (phase != "confirm" || e.amount == null) return
  val capture = pendingCapture ?: UUID.randomUUID().toString()
  val text = expenseMessage(e)
  val request = OneTimeWorkRequestBuilder<QuickVoiceDelivery>()
   .setInputData(workDataOf("step" to "send", "capture" to capture, "text" to text))
   .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build()
  phase = "sending"; message = ""
  WorkManager.getInstance(getApplication()).enqueueUniqueWork("expense-$capture", ExistingWorkPolicy.KEEP, request)
  watchSend(request.id)
 }

 private fun watchSend(id: UUID) {
  sendWatch?.cancel()
  sendWatch = viewModelScope.launch {
   WorkManager.getInstance(getApplication()).getWorkInfoByIdFlow(id).collect { info ->
    when (info?.state) {
     WorkInfo.State.RUNNING -> { phase = "sending" }
     WorkInfo.State.SUCCEEDED -> { phase = "sent"; message = ""; sendWatch?.cancel() }
     WorkInfo.State.FAILED, WorkInfo.State.CANCELLED -> {
      phase = "confirm"; message = info.outputData.getString("error") ?: "发送失败，可重试记账。"
      sendWatch?.cancel()
     }
     else -> Unit
    }
   }
  }
 }

 private fun releaseRecorder() { runCatching { recorder?.release() }; recorder = null }
 override fun onCleared() { transcribeWatch?.cancel(); sendWatch?.cancel(); timer?.cancel(); runCatching { recorder?.stop() }; releaseRecorder(); super.onCleared() }
}
