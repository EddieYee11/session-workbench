package work.eddie.sessions

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Deterministic inset frames complement the real MainActivity IME instrumentation. */
class KeyboardLayoutExperienceTest {
    @get:Rule val ui = createComposeRule()

    private fun bounds(tag: String): Rect = ui.onNodeWithTag(tag, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot

    private fun capture(name: String): Bitmap {
        val bitmap = ui.onNodeWithTag("keyboard-test-root").captureToImage().asAndroidBitmap()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        File(context.getExternalFilesDir(null), "com-keyboard-$name.png").outputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        return bitmap
    }

    @Test fun firstInsetFrameDoesNotDropComposerAndNavigationFadesWithItsReservedHeight() {
        var keyboardPx by mutableIntStateOf(0)
        var density = 1f
        var draft by mutableStateOf("键盘草稿")
        var navClicks = 0
        ui.setContent {
            density = LocalDensity.current.density
            val nav = WindowInsets(0, 0, 0, (24 * density).toInt())
            val ime = WindowInsets(0, 0, 0, keyboardPx)
            MaterialTheme(colorScheme = Palette) {
                Box(Modifier.width(300.dp).height(620.dp).background(Paper).testTag("keyboard-test-root")) {
                    Column(Modifier.fillMaxSize().windowInsetsPadding(nav).windowInsetsPadding(ime)) {
                        Text("固定页头", Modifier.fillMaxWidth().height(52.dp).testTag("keyboard-fixed-header"))
                        Box(Modifier.weight(1f).fillMaxWidth().background(HermesAssistantBubble).testTag("keyboard-viewport"))
                        Composer(draft, { draft = it }, "消息", true, false, {}, {}, {})
                        ImeAwareBottomNavigation(ime = ime, navigation = nav) { enabled ->
                            Box(Modifier.fillMaxWidth().height(80.dp).background(Color(0xFF263445))
                                .clickable(enabled = enabled) { navClicks++ }.testTag("keyboard-nav-content")) {
                                Text("测试导航", color = Color.White)
                            }
                        }
                    }
                }
            }
        }
        ui.waitForIdle()
        val header = bounds("keyboard-fixed-header")
        val composer = bounds("work-composer-surface")
        val nav = bounds("workbench-bottom-navigation")
        val viewport = bounds("keyboard-viewport")
        val frame0 = capture("frame0")
        ui.onNodeWithTag("keyboard-nav-content").performClick()
        assertEquals(1, navClicks)

        fun setIme(px: Int) { ui.runOnIdle { keyboardPx = px }; ui.waitForIdle() }
        val systemNavigation = (24 * density).toInt()
        setIme(systemNavigation + 1)
        assertEquals("The first inset pixel keeps the composer at its resting position", composer.bottom, bounds("work-composer-surface").bottom, 1.1f)
        assertEquals(header.top, bounds("keyboard-fixed-header").top, .1f)
        assertEquals(nav.height - 1f, bounds("workbench-bottom-navigation").height, 1.1f)
        ui.onAllNodesWithText("测试导航").assertCountEquals(0)
        capture("first-inset")

        setIme(systemNavigation + (nav.height / 2).toInt())
        assertEquals(composer.bottom, bounds("work-composer-surface").bottom, 1.1f)
        assertEquals(nav.height / 2, bounds("workbench-bottom-navigation").height, 1.1f)
        val half = capture("half")
        assertFalse("The navigation's actual pixels fade during the same inset progress", frame0.sameAs(half))

        val fullKeyboard = systemNavigation + nav.height.toInt() + (120 * density).toInt()
        setIme(fullKeyboard)
        assertEquals(0f, bounds("workbench-bottom-navigation").height, .1f)
        assertEquals(composer.bottom - 120 * density, bounds("work-composer-surface").bottom, 2f)
        assertEquals(viewport.height - 120 * density, bounds("keyboard-viewport").height, 2f)
        assertEquals(header.top, bounds("keyboard-fixed-header").top, .1f)
        assertEquals("键盘草稿", draft)
        capture("raised")

        setIme(0)
        assertEquals(composer.bottom, bounds("work-composer-surface").bottom, .1f)
        assertEquals(nav.height, bounds("workbench-bottom-navigation").height, .1f)
        ui.onNodeWithTag("keyboard-nav-content").performClick()
        assertEquals(2, navClicks)
        capture("restored")
    }

    @Test fun viewportResizeKeepsLatestAtBottomAndHistoryAtItsExactAnchor() {
        var height by mutableStateOf(340.dp)
        var width by mutableStateOf(300.dp)
        lateinit var list: LazyListState
        lateinit var scope: CoroutineScope
        ui.setContent {
            list = rememberLazyListState()
            scope = rememberCoroutineScope()
            MessageViewportAnchor(list, "keyboard-anchor-fixture")
            LazyColumn(state = list, modifier = Modifier.width(width).height(height).testTag("anchor-list"),
                contentPadding = PaddingValues(top = 12.dp, bottom = 18.dp)) {
                items(80, key = { it }) { i -> Text("历史消息 $i", Modifier.fillMaxWidth().height(48.dp)) }
            }
        }
        ui.onNodeWithTag("anchor-list").performScrollToIndex(79)
        ui.runOnIdle { assertFalse(list.canScrollForward); height = 210.dp }
        ui.waitForIdle()
        ui.runOnIdle { assertFalse("Latest reading remains at the viewport bottom", list.canScrollForward); height = 400.dp }
        ui.waitForIdle()
        ui.runOnIdle { assertFalse(list.canScrollForward); scope.launch { list.scrollToItem(20, 13) } }
        ui.waitForIdle()
        var first = 0
        var offset = 0
        ui.runOnIdle { first = list.firstVisibleItemIndex; offset = list.firstVisibleItemScrollOffset; height = 230.dp; width = 520.dp }
        ui.waitForIdle()
        ui.runOnIdle {
            assertEquals("A history reader keeps the same item", first, list.firstVisibleItemIndex)
            assertEquals("A history reader keeps its offset", offset, list.firstVisibleItemScrollOffset)
            assertTrue(list.canScrollForward)
        }
    }

    @Test fun emptyPlaceholderAndSingleLineDraftReserveTheSameComposerHeight() {
        var draft by mutableStateOf("")
        ui.setContent {
            MaterialTheme(colorScheme = Palette) {
                Column(Modifier.width(300.dp).height(400.dp)) {
                    Box(Modifier.weight(1f).fillMaxWidth().testTag("single-line-viewport"))
                    Composer(draft, { draft = it }, "继续和 Pi 聊聊…", true, false, {}, {}, {})
                }
            }
        }
        val restingComposer = bounds("work-composer-surface")
        val restingViewport = bounds("single-line-viewport")
        ui.runOnIdle { draft = "保留草稿 pi" }
        ui.waitForIdle()
        assertEquals("Typing one line must not shrink the placeholder's line box", restingComposer.height, bounds("work-composer-surface").height, .1f)
        assertEquals(restingViewport.height, bounds("single-line-viewport").height, .1f)
    }
}
