package work.eddie.sessions

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Synthetic content stays on the emulator; no requests or mutations of real conversations. */
class HermesExperienceTest {
    @get:Rule val ui = createComposeRule()

    private fun capture(name: String) {
        ui.waitForIdle()
        ui.mainClock.advanceTimeBy(500)
        android.os.SystemClock.sleep(350)
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(context.getExternalFilesDir(null), "com151-$name.png").outputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    @Test fun gradientHeaderOverlaysListAndReactionsStayAttachedToUser() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        lateinit var vm: WorkbenchModel
        ui.runOnUiThread {
            vm = WorkbenchModel(app)
            vm.active = false
            vm.hermesFresh = true
            vm.hermes = JSONObject().put("conversation_id", "ui-only").put("messages", JSONArray()
                .put(JSONObject().put("id", "user").put("role", "user")
                    .put("text", "今天终于把一件困难的事做好了。").put("status", "completed")
                    .put("reaction", JSONObject().put("emoji", "🎉").put("event_id", "test-event")))
                .put(JSONObject().put("id", "assistant").put("role", "assistant")
                    .put("text", "这一刻值得记住。慢慢来，我一直在。\n\n左右气泡使用不同的颜色，顶部也给阅读留出更多空间。")
                    .put("status", "completed")))
        }
        ui.setContent { MaterialTheme(colorScheme = Palette) { HermesChat(vm, {}, false, {}) } }
        ui.onNodeWithContentDescription("Pi 对这条消息的表情：🎉").assertIsDisplayed()
        ui.onNodeWithTag("hermes-user-bubble").assertIsDisplayed()
        ui.onNodeWithTag("hermes-assistant-bubble").assertIsDisplayed()
        val header = ui.onNodeWithTag("hermes-fading-header").fetchSemanticsNode().boundsInRoot
        val list = ui.onNodeWithTag("hermes-message-list").fetchSemanticsNode().boundsInRoot
        check(kotlin.math.abs(header.top - list.top) < 1f) { "Header must overlay scrolling content" }
        capture("conversation")
    }

    @Test fun nativeAvatarStatesRemainDistinct() {
        ui.setContent {
            MaterialTheme(colorScheme = Palette) {
                Column {
                    listOf("idle", "listening", "thinking", "working", "responding", "error", "offline").chunked(3).forEach { row ->
                        Row { row.forEach { state -> HermesCompanion(state, Modifier.size(124.dp)) } }
                    }
                }
            }
        }
        ui.onNodeWithContentDescription("Pi 螃蟹伙伴，听着呢…").assertIsDisplayed()
        ui.onNodeWithContentDescription("Pi 螃蟹伙伴，想想啊…").assertIsDisplayed()
        ui.onNodeWithContentDescription("Pi 螃蟹伙伴，离线了，稍后再试").assertIsDisplayed()
        capture("avatar-states")
    }
}
