package work.eddie.sessions

import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.unit.IntSize
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MessageSendMotionTest {
    @Test fun tenLinesMayMorphButLongOrReflowedTextKeepsItsRealBubble() {
        assertEquals(MessageSendTransitionKind.Morph, classifyMessageSendTransition("十行以内", 10, 10))
        assertEquals(MessageSendTransitionKind.Fallback, classifyMessageSendTransition("很多内容", 11, 11))
        assertEquals(MessageSendTransitionKind.Fallback, classifyMessageSendTransition("换行已改变", 2, 2, sameLineBreaks = false))
    }

    @Test fun codeMarkdownAndMediaPreserveOriginalRendering() {
        listOf("```kotlin\nval answer = 42\n```", "![图](file.png)", "# 标题", "**加粗**").forEach {
            assertEquals(MessageSendTransitionKind.Fallback, classifyMessageSendTransition(it, 1, 1))
        }
        assertEquals(MessageSendTransitionKind.Fallback, classifyMessageSendTransition("", 1, 1, MessageSendContentKind.Image))
        assertEquals(MessageSendTransitionKind.Morph, classifyMessageSendTransition("你好，今天怎么样？🙂", 1, 1))
    }

    @Test fun measurementAndRemoteReceiptCannotInventALocalSend() {
        val state = MessageSendMotionState()
        state.retarget("old", "remote-history")
        state.updateTargetContent("remote-history", MessageSendContentKind.Image)
        assertFalse(state.shouldHideTarget("remote-history"))
        assertFalse(state.begin("", "没有消息编号"))
        assertTrue(state.begin("local-send", "本次发送"))
        state.retarget("another-send", "other-receipt")
        assertEquals("local-send", state.transition?.messageId)
        state.retarget("local-send", "accepted-id")
        assertEquals("accepted-id", state.transition?.messageId)
        state.setEnabled(false)
        assertFalse(state.begin("next", "关闭动画后直接显示"))
        assertFalse(state.shouldHideTarget("accepted-id"))
    }

    @Test fun interruptedOlderFlightCannotCancelANewerSend() {
        val state = MessageSendMotionState()
        state.begin("first", "第一条")
        val oldSequence = state.transition!!.sequence
        state.start(oldSequence)
        state.begin("second", "第二条")
        state.finish(oldSequence)
        assertEquals("second", state.transition?.messageId)
        state.finish(state.transition!!.sequence)
        assertFalse(state.shouldHideTarget("second"))
    }

    @Test fun clippedOrInternallyScrolledComposerCannotPretendItsFullTextIsVisible() {
        val field = Rect(10f, 100f, 210f, 210f)
        assertTrue(messageSendSourceFullyVisible(IntSize(200, 110), field, field))
        assertFalse(messageSendSourceFullyVisible(IntSize(200, 176), field, field))
        assertFalse(messageSendSourceFullyVisible(IntSize(200, 110), field, Rect(10f, 125f, 210f, 210f)))
        assertEquals(MessageSendTransitionKind.Fallback,
            classifyMessageSendTransition("输入框里只显示了最后几行", 8, 8, sourceFullyVisible = false))
    }

    @Test fun voiceHandOffNeverReusesAnUnrelatedTypedComposerForAMorph() {
        val state = MessageSendMotionState()
        assertTrue(state.beginFallback("voice-local-send", "录音转写的消息"))
        assertEquals(MessageSendTransitionKind.Fallback, state.transition?.transitionKind)
        state.setEnabled(false)
        assertFalse(state.beginFallback("next-voice", "禁动画后直接显示"))
    }

    @Test fun modalSourceCannotBeOverwrittenByTheMainWindowsLayoutCallbacks() {
        val state = MessageSendMotionState()
        val modal = Any()
        val modalBounds = Rect(40f, 80f, 240f, 120f)
        state.updateComposerBounds(modalBounds, coordinateSpace = MessageSendCoordinateSpace.Screen, sourceKey = modal)
        state.updateComposerBounds(Rect(20f, 600f, 320f, 640f))
        assertTrue(state.begin("advanced-create", "高级新建的消息", sourceKey = modal))
        assertEquals(modalBounds, state.transition?.source?.textBounds)
        assertEquals(MessageSendCoordinateSpace.Screen, state.transition?.source?.textSpace)
        state.updateComposerBounds(Rect(20f, 400f, 320f, 440f))
        assertEquals(modalBounds, state.transition?.source?.textBounds)
    }
}
