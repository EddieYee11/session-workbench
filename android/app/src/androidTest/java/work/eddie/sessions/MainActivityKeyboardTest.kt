package work.eddie.sessions

import android.animation.ValueAnimator
import android.graphics.Bitmap
import android.os.Build
import android.os.SystemClock
import android.view.View
import android.view.ViewTreeObserver
import android.view.inspector.WindowInspector
import android.view.WindowManager
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import kotlin.math.abs

/** Real Activity window + native IME clock. It never sends a message or creates a remote session. */
class MainActivityKeyboardTest {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()
    private var vm: WorkbenchModel? = null
    private var oldHermesDraft: String? = null
    private var oldNewDraft: String? = null
    private var savedNewDraft = false
    private var workFixtureScope: String? = null
    private var oldWorkDraft: String? = null
    private var recorder: NativeFrames? = null

    private data class Frame(val ime: Int, val nav: Int, val headerTop: Float, val composerBottom: Float, val viewportHeight: Float)

    /** Read already-obtained nodes on pre-draw, after the native inset frame has reached Compose layout. */
    private class NativeFrames(
        private val decor: View,
        private val composer: SemanticsNode,
        private val header: SemanticsNode?,
        private val viewport: SemanticsNode?,
    ) : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE), ViewTreeObserver.OnPreDrawListener {
        val frames = mutableListOf<Frame>()
        private var latest: WindowInsetsCompat? = ViewCompat.getRootWindowInsets(decor)
        private var animating = false
        override fun onPrepare(animation: WindowInsetsAnimationCompat) {
            if (animation.typeMask and WindowInsetsCompat.Type.ime() != 0) animating = true
        }
        override fun onEnd(animation: WindowInsetsAnimationCompat) {
            if (animation.typeMask and WindowInsetsCompat.Type.ime() != 0) { animating = false; latest = ViewCompat.getRootWindowInsets(decor) }
        }
        override fun onProgress(insets: WindowInsetsCompat, runningAnimations: MutableList<WindowInsetsAnimationCompat>): WindowInsetsCompat {
            latest = insets
            return insets
        }
        override fun onPreDraw(): Boolean {
            val insets = if (animating) latest else ViewCompat.getRootWindowInsets(decor)
            if (insets == null) return true
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            val nav = insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom
            if (ime > nav) synchronized(frames) {
                frames += Frame(ime, nav, header?.boundsInWindow?.top ?: 0f, composer.boundsInWindow.bottom,
                    viewport?.boundsInWindow?.height ?: 0f)
            }
            return true
        }
        fun attach() { ViewCompat.setWindowInsetsAnimationCallback(decor, this); decor.viewTreeObserver.addOnPreDrawListener(this) }
        fun detach() { ViewCompat.setWindowInsetsAnimationCallback(decor, null); decor.viewTreeObserver.removeOnPreDrawListener(this) }
    }

    private fun node(tag: String) = ui.onNodeWithTag(tag, useUnmergedTree = true).fetchSemanticsNode()

    private fun fixture(): WorkbenchModel {
        lateinit var model: WorkbenchModel
        ui.runOnUiThread {
            model = ViewModelProvider(ui.activity)[WorkbenchModel::class.java]
            oldHermesDraft = model.hermesDraft
            oldNewDraft = model.store.prefs.getString("new-draft", null)
            savedNewDraft = true
            model.store.prefs.edit().remove("new-draft").commit()
            model.active = false
            model.connected = false
            model.error = ""
            model.hermesVoicePhase = "idle"
            model.hermesVoiceNote = ""
            model.hermesSendNote = ""
            model.hermesOutbox = emptyList()
            model.hermesReference = null
            model.hermesDraft = ""
            model.hermesFresh = false
            model.hermesLoading = false
            model.hermesError = ""
            model.hermes = JSONObject().put("conversation_id", "local-keyboard-fixture").put("messages", JSONArray().apply {
                repeat(24) { i -> put(JSONObject().put("id", "keyboard-message-$i").put("role", if (i % 2 == 0) "user" else "assistant")
                    .put("text", "键盘布局本地消息 $i").put("status", "completed")) }
            })
        }
        vm = model
        ui.waitForIdle()
        // A clean emulator opens the pairing sheet. Dismiss it without changing credentials.
        if (ui.onAllNodesWithText("完成").fetchSemanticsNodes().isNotEmpty()) ui.onNodeWithText("完成").performClick()
        ui.waitForIdle()
        return model
    }

    private fun capture(label: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val width = context.resources.configuration.screenWidthDp
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(context.getExternalFilesDir(null), "com-native-ime-${width}dp-$label.png").outputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    private fun exercise(composerTag: String, headerTag: String, viewportTag: String, label: String) {
        val decor = ui.activity.window.decorView
        val composer = node(composerTag)
        val header = node(headerTag)
        val viewport = node(viewportTag)
        val beforeBottom = composer.boundsInWindow.bottom
        val beforeTop = header.boundsInWindow.top
        val beforeHeight = viewport.boundsInWindow.height
        assertEquals(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE,
            ui.activity.window.attributes.softInputMode and WindowManager.LayoutParams.SOFT_INPUT_MASK_ADJUST)
        recorder = NativeFrames(decor, composer, header, viewport).also { frames -> ui.runOnUiThread { frames.attach() } }
        capture("$label-resting")
        ui.onNodeWithTag(composerTag).performClick().performTextInput("保留草稿 $label")
        ui.runOnUiThread { WindowInsetsControllerCompat(ui.activity.window, decor).show(WindowInsetsCompat.Type.ime()) }
        ui.waitUntil(5_000) { ViewCompat.getRootWindowInsets(decor)?.isVisible(WindowInsetsCompat.Type.ime()) == true }
        SystemClock.sleep(450) // Android, not Compose's mainClock, drives IME frames.
        ui.waitForIdle()
        val keyboard = checkNotNull(ViewCompat.getRootWindowInsets(decor)).getInsets(WindowInsetsCompat.Type.ime()).bottom
        assertTrue(keyboard > 0)
        assertEquals(beforeTop, node(headerTag).boundsInWindow.top, 2f)
        assertTrue("Composer stays above the real keyboard", node(composerTag).boundsInWindow.bottom <= decor.height - keyboard + 2)
        assertTrue("Message viewport shrinks with the keyboard", node(viewportTag).boundsInWindow.height < beforeHeight)
        ui.onAllNodesWithContentDescription("工作").assertCountEquals(0)
        val samples = synchronized(checkNotNull(recorder).frames) { checkNotNull(recorder).frames.toList() }
        assertTrue("Record actual native inset/layout frames", samples.isNotEmpty())
        samples.forEach { frame ->
            assertTrue("No first-frame downward jump: $frame", frame.composerBottom <= beforeBottom + 2)
            assertTrue("Header remains fixed during every native frame", abs(frame.headerTop - beforeTop) <= 2)
        }
        if (ValueAnimator.areAnimatorsEnabled()) assertTrue("Native animated frames must change the inset", samples.map { it.ime }.distinct().size > 1)
        capture("$label-raised")
        ui.runOnUiThread { WindowInsetsControllerCompat(ui.activity.window, decor).hide(WindowInsetsCompat.Type.ime()) }
        ui.waitUntil(5_000) { ViewCompat.getRootWindowInsets(decor)?.isVisible(WindowInsetsCompat.Type.ime()) == false }
        SystemClock.sleep(450)
        ui.waitForIdle()
        ui.onNodeWithTag(composerTag).assertTextContains("保留草稿 $label").assertIsFocused()
        assertEquals(beforeBottom, node(composerTag).boundsInWindow.bottom, 2f)
        assertEquals(beforeHeight, node(viewportTag).boundsInWindow.height, 2f)
        ui.onNodeWithContentDescription("工作").assertIsDisplayed()
        capture("$label-restored")
    }

    @Test fun hermesWindowMovesComposerAndViewportWithTheNativeKeyboard() {
        fixture()
        exercise("hermes-composer", "hermes-fading-header", "hermes-message-list", "hermes")
    }

    private fun work(agent: String) {
        val model = fixture()
        ui.onNodeWithContentDescription("工作").performClick()
        ui.runOnUiThread {
            model.selected = "local-keyboard-$agent"
            workFixtureScope = model.selected
            oldWorkDraft = model.store.prefs.getString("draft:${model.selected}", null)
            model.setDraft("")
            model.detail = JSONObject().put("session", JSONObject().put("id", model.selected).put("agent", agent)
                .put("display_title", "键盘布局 · $agent").put("status", "ready")
                .put("capabilities", JSONObject().put("input", true).put("terminal", false))).put("messages", JSONArray().apply {
                repeat(24) { i -> put(JSONObject().put("id", "$agent-row-$i").put("role", if (i % 2 == 0) "user" else "assistant").put("text", "本地消息 $i")) }
            })
            model.live = JSONObject()
        }
        ui.waitForIdle()
        exercise("work-composer", "work-fixed-header", "work-message-viewport", agent)
    }

    @Test fun piWindowKeepsItsHeaderFixedAndDraftVisible() = work("pi")
    @Test fun codexWindowKeepsItsHeaderFixedAndDraftVisible() = work("codex")

    @Test fun advancedModalConsumesItsOwnKeyboardInsetsOnce() {
        fixture()
        ui.onNodeWithContentDescription("工作").performClick()
        ui.onNodeWithContentDescription("新会话设置").performClick()
        ui.onNodeWithTag("advanced-session-composer").performClick().performTextInput("高级窗口草稿")
        ui.waitForIdle()
        val decor = if (Build.VERSION.SDK_INT >= 29) WindowInspector.getGlobalWindowViews().last { it.hasWindowFocus() } else ui.activity.window.decorView
        ui.waitUntil(5_000) { ViewCompat.getRootWindowInsets(decor)?.isVisible(WindowInsetsCompat.Type.ime()) == true }
        SystemClock.sleep(450)
        ui.waitForIdle()
        val ime = checkNotNull(ViewCompat.getRootWindowInsets(decor)).getInsets(WindowInsetsCompat.Type.ime()).bottom
        assertTrue(ime > 0)
        assertTrue("The modal's real composer is above its keyboard", node("advanced-session-composer").boundsInWindow.bottom <= decor.height - ime + 2)
        ui.onNodeWithTag("advanced-session-composer").assertTextContains("高级窗口草稿").assertIsFocused()
        capture("advanced-raised")
        ui.runOnUiThread { ViewCompat.getWindowInsetsController(decor)?.hide(WindowInsetsCompat.Type.ime()) }
        ui.waitUntil(5_000) { ViewCompat.getRootWindowInsets(decor)?.isVisible(WindowInsetsCompat.Type.ime()) == false }
        SystemClock.sleep(450)
        ui.onNodeWithTag("advanced-session-composer").assertTextContains("高级窗口草稿")
        capture("advanced-restored")
    }

    @After fun restoreLocalDraftAndRemoveObserver() {
        ui.runOnUiThread {
            recorder?.detach()
            ViewCompat.getWindowInsetsController(ui.activity.window.decorView)?.hide(WindowInsetsCompat.Type.ime())
            oldHermesDraft?.let { vm?.updateHermesDraft(it) }
            vm?.store?.prefs?.edit()?.let { editor ->
                if (savedNewDraft) { if (oldNewDraft == null) editor.remove("new-draft") else editor.putString("new-draft", oldNewDraft) }
                workFixtureScope?.let { scope -> if (oldWorkDraft == null) editor.remove("draft:$scope") else editor.putString("draft:$scope", oldWorkDraft) }
                editor.commit()
            }
            vm?.active = false
        }
    }
}
