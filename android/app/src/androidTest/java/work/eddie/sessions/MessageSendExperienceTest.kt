package work.eddie.sessions

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

/** Runs only local Compose fixtures. Server acceptance is simulated, with no network or account writes. */
class MessageSendExperienceTest {
    @get:Rule val ui = createComposeRule()

    private class Harness {
        var draft by mutableStateOf("")
        var reference by mutableStateOf<JSONObject?>(null)
        val native = mutableStateListOf<JSONObject>()
        val outgoing = mutableStateListOf<OutgoingMessage>()
        lateinit var motion: MessageSendMotionState
        var hideKeyboard: () -> Unit = {}
        var sends = 0
        var lastId = ""
        var lastText = ""
        var rootScreenBounds = Rect.Zero
        var height by mutableStateOf(570.dp)
        lateinit var list: LazyListState

        fun send() = dispatch(false)

        fun sendExternalTranscript(text: String) {
            draft = text
            dispatch(true)
        }

        private fun dispatch(withoutVisibleSource: Boolean) {
            if (draft.isBlank()) return
            val text = draft
            val id = "local-send-${sends + 1}"
            if (withoutVisibleSource) motion.beginFallback(id, text) else motion.begin(id, text)
            sends++
            lastId = id
            lastText = text
            outgoing += OutgoingMessage(id, "test-session", text, reference,
                previousIds = native.map { it.optString("id") }.toSet())
            draft = ""
            reference = null
            hideKeyboard()
        }

        fun accept() {
            native += JSONObject().put("id", "server-${sends}").put("request_id", lastId)
                .put("role", "user").put("text", lastText).put("status", "completed")
            val index = outgoing.indexOfFirst { it.id == lastId }
            outgoing[index] = outgoing[index].copy(status = "sent", serverId = "server-${sends}")
        }
    }

    @Composable private fun Fixture(harness: Harness, width: Dp) {
        // Direct state makes this controlled clock fixture independent of the
        // emulator's global animation-scale setting, without changing that setting.
        val motion = remember { MessageSendMotionState() }
        val keyboard = LocalSoftwareKeyboardController.current
        val view = LocalView.current
        val list = rememberLazyListState()
        SideEffect { harness.motion = motion; harness.list = list; harness.hideKeyboard = { keyboard?.hide() } }
        val rows = mergeOutgoingMessages(harness.native.toList(), harness.outgoing.toList())
        val targetIndex = motion.messageId?.let { id -> rows.indexOfFirst { messageMotionId(it) == id }.takeIf { it >= 0 } }
        MessageSendListScroll(motion, list, targetIndex)
        MaterialTheme(colorScheme = Palette) {
            Box(Modifier.width(width).height(harness.height).background(Paper).testTag("send-test-root")
                .onGloballyPositioned { harness.rootScreenBounds = it.messageSendBoundsOnScreen(view) }) {
                Column(Modifier.fillMaxSize()) {
                    Text("Com! · 发送", Modifier.padding(horizontal = 20.dp, vertical = 15.dp), fontSize = 17.sp, color = Ink)
                    LazyColumn(state = list, modifier = Modifier.weight(1f).fillMaxWidth().testTag("send-target-area"),
                        contentPadding = PaddingValues(20.dp)) {
                        items(rows, key = ::messageMotionId) { message ->
                            MessageSendRow(motion, messageMotionId(message), Modifier.testTag("send-row-${messageMotionId(message)}"), trailingSpacing = 16.dp) {
                                Message(message, "", 16f, "pi", motion)
                            }
                        }
                    }
                    harness.reference?.let { reference -> MessageReferencePreview(reference) { harness.reference = null } }
                    Composer(harness.draft, { harness.draft = it }, "消息", true, false, {}, harness::send, {}, motion = motion)
                }
                Box(Modifier.matchParentSize().testTag("send-motion-layer")) {
                    MessageSendMotionOverlay(motion, Modifier.matchParentSize())
                }
            }
        }
    }

    private fun prepare(width: Dp): Harness {
        ui.mainClock.autoAdvance = false
        val harness = Harness()
        ui.setContent { Fixture(harness, width) }
        ui.mainClock.advanceTimeBy(100)
        ui.waitForIdle()
        return harness
    }

    private fun typeAndSend(harness: Harness, text: String, viaButton: Boolean = false) {
        ui.onNodeWithTag("work-composer").performTextInput(text)
        ui.mainClock.advanceTimeByFrame()
        ui.runOnIdle { harness.hideKeyboard() }
        // Native IME resizing is driven by Android's clock, not the paused Compose
        // clock. Settle it before recording the send's source/target geometry.
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        android.os.SystemClock.sleep(350)
        ui.mainClock.advanceTimeByFrame()
        if (viaButton) ui.onNodeWithContentDescription("发送").performClick()
        else ui.onNodeWithTag("work-composer").performImeAction()
        // First frame measures the newly inserted target; the second supplies the
        // animation's initial frame at progress zero. The test clock stays paused.
        ui.mainClock.advanceTimeByFrame()
        ui.mainClock.advanceTimeByFrame()
        ui.waitForIdle()
    }

    private fun capture(name: String): Bitmap {
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        val bitmap = ui.onNodeWithTag("send-test-root").captureToImage().asAndroidBitmap()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        File(context.getExternalFilesDir(null), "com-send-$name.png").outputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        return bitmap
    }

    private fun targetColorPixels(bitmap: Bitmap, bounds: Rect, harness: Harness,
        space: MessageSendCoordinateSpace): Int {
        val root = if (space == MessageSendCoordinateSpace.Screen) harness.rootScreenBounds
            else ui.onNodeWithTag("send-test-root").fetchSemanticsNode().boundsInRoot
        val left = (bounds.left - root.left).roundToInt().coerceIn(0, bitmap.width)
        val top = (bounds.top - root.top).roundToInt().coerceIn(0, bitmap.height)
        val right = (bounds.right - root.left).roundToInt().coerceIn(left, bitmap.width)
        val bottom = (bounds.bottom - root.top).roundToInt().coerceIn(top, bitmap.height)
        val color = HermesUserBubble.toArgb()
        var count = 0
        for (y in top until bottom) for (x in left until right) {
            val pixel = bitmap.getPixel(x, y)
            if (abs(android.graphics.Color.red(pixel) - android.graphics.Color.red(color)) <= 3 &&
                abs(android.graphics.Color.green(pixel) - android.graphics.Color.green(color)) <= 3 &&
                abs(android.graphics.Color.blue(pixel) - android.graphics.Color.blue(color)) <= 3) count++
        }
        return count
    }

    private fun assertFramesDiffer(a: Bitmap, b: Bitmap) {
        assertEquals(a.width, b.width)
        assertEquals(a.height, b.height)
        var changed = 0
        for (y in 0 until a.height step 2) for (x in 0 until a.width step 2) {
            if (a.getPixel(x, y) != b.getPixel(x, y)) changed++
        }
        assertTrue("The captured frames must show actual changing pixels", changed > 20)
    }

    private fun plainSend(width: Dp, name: String) {
        val harness = prepare(width)
        typeAndSend(harness, "你好")
        lateinit var target: Rect
        var targetSpace = MessageSendCoordinateSpace.Root
        ui.runOnIdle {
            assertEquals(1, harness.sends)
            assertEquals("", harness.draft)
            val transition = checkNotNull(harness.motion.transition)
            assertTrue("The actual target must have measured geometry", transition.ready)
            assertEquals(MessageSendTransitionKind.Morph, transition.transitionKind)
            assertEquals(0f, harness.motion.progress, .001f)
            target = checkNotNull(transition.target.bubbleBounds)
            targetSpace = transition.target.bubbleSpace
            assertTrue(harness.motion.shouldHideTarget(harness.lastId))
        }
        val frame0 = capture("$name-frame0")
        assertEquals("The stationary target must not duplicate the flying text", 0, targetColorPixels(frame0, target, harness, targetSpace))
        ui.mainClock.advanceTimeBy(125)
        ui.runOnIdle {
            assertTrue(harness.motion.progress > 0f && harness.motion.progress < 1f)
            harness.accept()
        }
        ui.waitForIdle()
        ui.onAllNodesWithText("你好", useUnmergedTree = true).assertCountEquals(1)
        val middle = capture("$name-frame125")
        assertFramesDiffer(frame0, middle)
        ui.mainClock.advanceTimeBy(300)
        ui.runOnIdle {
            assertNull("A completed send returns to idle", harness.motion.transition)
            assertFalse(harness.motion.shouldHideTarget(harness.lastId))
            assertEquals(1, mergeOutgoingMessages(harness.native.toList(), harness.outgoing.toList()).size)
            assertEquals(1, harness.sends)
        }
        val end = capture("$name-end")
        assertTrue("The settled target bubble must be visibly restored", targetColorPixels(end, target, harness, targetSpace) > 100)
        assertFramesDiffer(middle, end)
        ui.onNodeWithText("已发送").assertIsDisplayed()
    }

    @Test fun narrowImeSendFliesIntoExactlyOneSettledBubble() = plainSend(300.dp, "narrow")
    @Test fun wideImeSendFliesIntoExactlyOneSettledBubble() = plainSend(620.dp, "wide")

    @Test fun buttonSendUsesOneLocalFlightAndOneSettledBubble() {
        val harness = prepare(360.dp)
        typeAndSend(harness, "点击按钮发送", viaButton = true)
        ui.runOnIdle {
            assertEquals(1, harness.sends)
            assertEquals("local-send-1", harness.motion.messageId)
            assertEquals(MessageSendTransitionKind.Morph, harness.motion.transition?.transitionKind)
            harness.accept()
        }
        ui.mainClock.advanceTimeBy(350)
        ui.runOnIdle { assertNull(harness.motion.transition); assertEquals(1, harness.sends) }
        ui.onAllNodesWithText("点击按钮发送", useUnmergedTree = true).assertCountEquals(1)
        ui.onNodeWithText("已发送").assertIsDisplayed()
    }

    @Test fun externalVoiceTranscriptKeepsTheSameLocalIdentityAndUsesTheRealBubbleFallback() {
        val harness = prepare(360.dp)
        ui.runOnIdle { harness.sendExternalTranscript("识别后的语音消息") }
        ui.mainClock.advanceTimeByFrame()
        ui.mainClock.advanceTimeByFrame()
        ui.runOnIdle {
            assertEquals(1, harness.sends)
            assertEquals("local-send-1", harness.motion.messageId)
            assertEquals(MessageSendTransitionKind.Fallback, harness.motion.transition?.transitionKind)
            assertTrue(checkNotNull(harness.motion.transition).ready)
            harness.accept()
        }
        ui.mainClock.advanceTimeBy(350)
        ui.runOnIdle { assertNull(harness.motion.transition); assertEquals(1, harness.sends) }
        ui.onAllNodesWithText("识别后的语音消息", useUnmergedTree = true).assertCountEquals(1)
    }

    @Test fun internallyScrolledEightLineComposerUsesFallbackEvenWithMatchingTargetLineBreaks() {
        val harness = prepare(360.dp)
        typeAndSend(harness, (1..8).joinToString("\n") { "第${it}行" })
        ui.runOnIdle {
            val flight = checkNotNull(harness.motion.transition)
            assertTrue(checkNotNull(flight.source.text).layout.lineCount in 1..10)
            assertEquals(MessageSendTransitionKind.Fallback, flight.transitionKind)
        }
        ui.mainClock.advanceTimeBy(350)
        ui.runOnIdle { assertNull(harness.motion.transition); assertEquals(1, harness.sends) }
    }

    @Test fun viewportResizeDuringFlightDoesNotRestartOrDuplicateTheSend() {
        val harness = prepare(360.dp)
        typeAndSend(harness, "布局在发送中变化")
        ui.mainClock.advanceTimeBy(64)
        var sequence = 0L
        var progress = 0f
        ui.runOnIdle {
            sequence = checkNotNull(harness.motion.localSendSequence)
            progress = harness.motion.progress
            harness.height = 500.dp
        }
        ui.mainClock.advanceTimeBy(32)
        ui.runOnIdle {
            assertEquals(sequence, harness.motion.localSendSequence)
            assertTrue(harness.motion.progress >= progress)
            assertEquals(1, harness.sends)
        }
        ui.mainClock.advanceTimeBy(350)
        ui.runOnIdle { assertNull(harness.motion.transition); assertEquals(1, harness.sends) }
    }

    @Test fun explicitNewlineEditsDraftWithoutSendingThenImeSendsOnce() {
        val harness = prepare(360.dp)
        ui.onNodeWithTag("work-composer").performTextInput("第一行")
        ui.mainClock.advanceTimeByFrame()
        ui.onNodeWithContentDescription("插入换行").performClick()
        ui.mainClock.advanceTimeByFrame()
        ui.runOnIdle { assertEquals("第一行\n", harness.draft); assertEquals(0, harness.sends); assertNull(harness.motion.transition) }
        ui.onNodeWithTag("work-composer").performTextInput("第二行")
        ui.mainClock.advanceTimeByFrame()
        ui.onNodeWithTag("work-composer").performImeAction()
        ui.mainClock.advanceTimeBy(350)
        ui.runOnIdle { assertEquals(1, harness.sends); assertEquals("第一行\n第二行", harness.lastText); assertEquals("", harness.draft) }
    }

    @Test fun markdownUsesRichBubbleFallbackAndNeverDrawsAFalseTextMorph() {
        val harness = prepare(360.dp)
        typeAndSend(harness, "```kotlin\nprintln(\"hello\")\n```")
        ui.runOnIdle {
            val transition = checkNotNull(harness.motion.transition)
            assertTrue(transition.ready)
            assertEquals(MessageSendTransitionKind.Fallback, transition.transitionKind)
            assertFalse("Fallback animates the real rendered rich bubble", harness.motion.shouldHideTarget(harness.lastId))
        }
        val start = capture("markdown-frame0")
        ui.mainClock.advanceTimeBy(125)
        val middle = capture("markdown-frame125")
        assertFramesDiffer(start, middle)
        ui.mainClock.advanceTimeBy(300)
        ui.runOnIdle { assertNull(harness.motion.transition); assertEquals(1, harness.sends) }
        val end = capture("markdown-end")
        assertFramesDiffer(middle, end)
        ui.onNodeWithText("发送中").assertIsDisplayed()
    }

    @Test fun swipeReplyPreviewCanBeClosedWithoutSendingOrDeletingMessage() {
        ui.mainClock.autoAdvance = false
        var reference by mutableStateOf<JSONObject?>(null)
        var replies = 0
        val message = JSONObject().put("id", "reply-source").put("role", "assistant").put("text", "这是需要回复的消息。")
        ui.setContent {
            MaterialTheme(colorScheme = Palette) {
                Column(Modifier.width(360.dp).background(Paper)) {
                    MessageSwipeActions(message, onReply = {
                        replies++
                        reference = messageReference(it, "reply", "Pi", "test-session")
                    }, onForward = { reference = messageReference(it, "forward", "Pi", "test-session") }) {
                        Message(message, "", 16f, "pi")
                    }
                    reference?.let { MessageReferencePreview(it) { reference = null } }
                }
            }
        }
        ui.mainClock.advanceTimeByFrame()
        ui.onNodeWithTag("message-swipe-reply-source").performTouchInput {
            swipe(start = Offset(width * .2f, height * .4f), end = Offset(width * .8f, height * .4f), durationMillis = 180)
        }
        ui.mainClock.advanceTimeBy(400)
        ui.onNodeWithTag("message-reference-preview").assertIsDisplayed()
        ui.onNodeWithContentDescription("取消回复").performClick()
        ui.mainClock.advanceTimeByFrame()
        ui.onNodeWithTag("message-reference-preview").assertDoesNotExist()
        ui.runOnIdle { assertEquals(1, replies); assertNull(reference) }
        ui.onNodeWithTag("message-swipe-reply-source").assertIsDisplayed()
    }
}
