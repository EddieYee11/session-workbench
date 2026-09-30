package work.eddie.sessions

import org.junit.Assert.*
import org.junit.Test

class QuickVoiceTest {
    @Test fun initialSilenceAndSingleBumpNeverSend() {
        val detector = SpeechEndpointDetector()
        for (t in 0L..2000L step 50) assertFalse(detector.sample(80, t))
        assertFalse(detector.sample(9000, 2050))
        for (t in 2100L..5000L step 50) assertFalse(detector.sample(80, t))
    }
    @Test fun sendsAtHalfSecondAfterLastSpeech() {
        val detector = SpeechEndpointDetector()
        for (t in 0L..300L step 50) assertFalse(detector.sample(1600, t))
        assertTrue(detector.heardSpeech)
        assertFalse(detector.sample(80, 799))
        assertTrue(detector.sample(80, 800))
    }
    @Test fun shortPauseThenSpeechRestartsSilenceClock() {
        val detector = SpeechEndpointDetector()
        for (t in 0L..300L step 50) detector.sample(1600, t)
        assertFalse(detector.sample(80, 750))
        assertFalse(detector.sample(1700, 790))
        assertFalse(detector.sample(80, 1289))
        assertTrue(detector.sample(80, 1290))
    }
    @Test fun terminalExitDoesNotLeaveWindowWaitingForever() {
        assertTrue(voiceReplyFinished("ended",false,false,false,10))
        assertTrue(voiceReplyFinished("failed",false,false,false,10))
        assertFalse(voiceReplyFinished("completed",false,false,false,10000))
        assertFalse(voiceReplyFinished("completed",false,false,true,100))
        assertTrue(voiceReplyFinished("completed",true,false,true,100))
        assertFalse(voiceReplyFinished("running",true,true,true,10000))
    }
    @Test fun followupDoesNotShowOldAnswerOrToolOutput() {
        val items = listOf(VoiceReplyItem("pi:100", "assistant", "旧回复"),
            VoiceReplyItem("pi:200", "user", "这次的问题"),
            VoiceReplyItem("pi:210", "assistant", "新的回复"),
            VoiceReplyItem("pi:215", "tool", "内部输出"),
            VoiceReplyItem("pi:220", "assistant", "补充内容"))
        assertEquals("新的回复\n\n补充内容", voiceReplyText(items, 100))
        assertEquals("", voiceReplyText(items, 220))
    }
}
