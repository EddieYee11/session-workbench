package work.eddie.sessions

import kotlin.math.max

/** Amplitude gate with a speech-onset guard: silence alone must never submit audio. */
internal class SpeechEndpointDetector(private val silenceMillis: Long = 500) {
    var heardSpeech = false
        private set
    private var noiseFloor = 120.0
    private var voiceStarted: Long? = null
    private var lastVoice: Long? = null

    fun sample(amplitude: Int, nowMillis: Long): Boolean {
        val threshold = max(if (heardSpeech) 420.0 else 650.0, noiseFloor * 3.0)
        if (amplitude >= threshold) {
            if (voiceStarted == null) voiceStarted = nowMillis
            if (nowMillis - voiceStarted!! >= 120) heardSpeech = true
            lastVoice = nowMillis
        } else {
            voiceStarted = null
            // Only learn the quiet floor; a cough or speech onset cannot raise the gate.
            if (!heardSpeech && amplitude < 650) noiseFloor = noiseFloor * .94 + amplitude * .06
        }
        return heardSpeech && lastVoice != null && nowMillis - lastVoice!! >= silenceMillis
    }
}

internal data class VoiceReplyItem(val id: String, val role: String, val text: String)
internal fun voiceReplyText(items: List<VoiceReplyItem>, after: Long): String = items
    .filter { it.role == "assistant" && (it.id.removePrefix("pi:").toLongOrNull() ?: 0L) > after }
    .distinctBy { it.id }.joinToString("\n\n") { it.text.trim() }.trim()

internal fun voiceReplyFinished(status:String,hasReply:Boolean,sawRunning:Boolean,hasCurrentItems:Boolean,elapsedMillis:Long):Boolean =
    status in listOf("ended","failed","interrupted") ||
        (status=="completed" && (hasReply || sawRunning || (hasCurrentItems && elapsedMillis>5000)))
