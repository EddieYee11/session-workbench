package work.eddie.sessions

import android.widget.TextView
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Gesture acceptance includes the selectable native text used by Pi/Codex chat. */
class MessageSwipeActionsUiTest {
    @get:Rule val ui = createComposeRule()

    @Test fun nativeSelectableMessageRepliesAndForwardsWithoutDisappearing() {
        val message = JSONObject().put("id", "native-message").put("text", "这是一段能选中复制的对话。")
        val replies = mutableListOf<JSONObject>()
        val forwards = mutableListOf<JSONObject>()
        ui.setContent {
            MaterialTheme(colorScheme = Palette) {
                MessageSwipeActions(message, Modifier.width(320.dp).height(96.dp),
                    onReply = { replies += it }, onForward = { forwards += it }) {
                    AndroidView(factory = { context -> TextView(context).apply {
                        text = message.getString("text")
                        setTextIsSelectable(true)
                        textSize = 18f
                    } }, modifier = Modifier.fillMaxSize())
                }
            }
        }
        val bubble = ui.onNodeWithTag("message-swipe-native-message")
        bubble.performTouchInput { swipe(start = Offset(width * .3f, height * .5f), end = Offset(width * .8f, height * .5f), durationMillis = 180) }
        ui.runOnIdle { assertEquals(1, replies.size); assertSame(message, replies.single()); assertTrue(forwards.isEmpty()) }
        ui.mainClock.advanceTimeBy(700)
        bubble.assertIsDisplayed()
        bubble.performTouchInput { swipe(start = Offset(width * .8f, height * .5f), end = Offset(width * .3f, height * .5f), durationMillis = 180) }
        ui.runOnIdle { assertEquals(1, replies.size); assertEquals(1, forwards.size); assertSame(message, forwards.single()) }
        ui.mainClock.advanceTimeBy(700)
        bubble.assertIsDisplayed()
    }

    @Test fun verticalDragScrollsParentAndLongPressDoesNotInvokeMessageActions() {
        var actions = 0
        var scroll: androidx.compose.foundation.ScrollState? = null
        val message = JSONObject().put("id", "scroll-message").put("text", "选择这段文字时不触发回复。")
        ui.setContent {
            val state = rememberScrollState()
            SideEffect { scroll = state }
            MaterialTheme(colorScheme = Palette) {
                Column(Modifier.width(320.dp).height(320.dp).verticalScroll(state)) {
                    MessageSwipeActions(message, Modifier.fillMaxWidth().height(240.dp),
                        onReply = { actions++ }, onForward = { actions++ }) {
                        AndroidView(factory = { context -> TextView(context).apply {
                            text = message.getString("text"); setTextIsSelectable(true); textSize = 18f
                        } }, modifier = Modifier.fillMaxSize())
                    }
                    Spacer(Modifier.height(700.dp))
                }
            }
        }
        val bubble = ui.onNodeWithTag("message-swipe-scroll-message")
        bubble.performTouchInput { swipe(start = Offset(width * .5f, height * .8f), end = Offset(width * .5f, height * .2f), durationMillis = 180) }
        ui.runOnIdle { assertEquals(0, actions); assertTrue(checkNotNull(scroll).value > 0) }
        ui.runOnIdle { checkNotNull(scroll).dispatchRawDelta(-checkNotNull(scroll).value.toFloat()) }
        ui.mainClock.advanceTimeByFrame()
        bubble.performTouchInput { longClick(Offset(width * .3f, height * .1f)) }
        ui.runOnIdle { assertEquals(0, actions) }
    }
}
