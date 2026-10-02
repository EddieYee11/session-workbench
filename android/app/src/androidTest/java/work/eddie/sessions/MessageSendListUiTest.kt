package work.eddie.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Real LazyColumn acceptance: row growth reserves space and moves existing content by that space. */
class MessageSendListUiTest {
    @get:Rule val ui = createComposeRule()

    private data class Row(val id: String, val height: Dp)
    private class Harness {
        val rows = mutableStateListOf<Row>().apply { repeat(6) { add(Row("old-$it", 48.dp)) } }
        val motion = MessageSendMotionState()
        lateinit var list: LazyListState
        val rowHeights = mutableMapOf<String, Int>()
    }

    @Composable private fun Fixture(harness: Harness) {
        val list = rememberLazyListState(initialFirstVisibleItemIndex = 5)
        SideEffect { harness.list = list }
        val target = harness.motion.messageId?.let { id -> harness.rows.indexOfFirst { it.id == id }.takeIf { it >= 0 } }
        MessageSendListScroll(harness.motion, list, target)
        MaterialTheme(colorScheme = Palette) {
            LazyColumn(state = list, modifier = Modifier.width(300.dp).height(300.dp).testTag("growth-list"),
                contentPadding = PaddingValues(bottom = 12.dp)) {
                items(harness.rows, key = { it.id }) { row ->
                    MessageSendRow(harness.motion, row.id,
                        modifier = Modifier.onSizeChanged { harness.rowHeights[row.id] = it.height }, trailingSpacing = 12.dp) {
                        if (row.id == "local-send") Column {
                            Box(Modifier.fillMaxWidth().height(row.height - 12.dp).background(Card).testTag(row.id))
                            Box(Modifier.fillMaxWidth().height(12.dp).messageSendMetadata(harness.motion, row.id).background(Color.Magenta))
                        } else Box(Modifier.fillMaxWidth().height(row.height).background(Card).testTag(row.id))
                    }
                }
            }
        }
    }

    private fun prepare(): Harness {
        ui.mainClock.autoAdvance = false
        val harness = Harness()
        ui.setContent { Fixture(harness) }
        ui.mainClock.advanceTimeBy(100)
        ui.waitForIdle()
        return harness
    }

    @Test fun localRowAndItsGapMoveTheExistingMessagesByExactlyTheirExpandedHeight() {
        val harness = prepare()
        ui.runOnIdle {
            harness.motion.beginFallback("local-send", "本机发送")
            harness.rows.add(Row("local-send", 150.dp))
        }
        ui.mainClock.advanceTimeBy(350)
        ui.waitForIdle()
        var initialOffset = 0
        ui.runOnIdle {
            initialOffset = harness.list.layoutInfo.visibleItemsInfo.single { it.key == "old-5" }.offset
            assertEquals(0, harness.rowHeights["local-send"])
            harness.motion.frame(.5f)
        }
        ui.mainClock.advanceTimeBy(32)
        ui.waitForIdle()
        var middleHeight = 0
        ui.runOnIdle {
            val items = harness.list.layoutInfo.visibleItemsInfo
            middleHeight = items.single { it.key == "local-send" }.size
            assertTrue(middleHeight > 0)
            assertEquals(middleHeight.toFloat(), (initialOffset - items.single { it.key == "old-5" }.offset).toFloat(), 2f)
            harness.motion.frame(1f)
        }
        ui.mainClock.advanceTimeBy(32)
        ui.waitForIdle()
        ui.runOnIdle {
            val items = harness.list.layoutInfo.visibleItemsInfo
            val finalHeight = items.single { it.key == "local-send" }.size
            assertEquals(middleHeight * 2f, finalHeight.toFloat(), 2f)
            assertEquals(finalHeight.toFloat(), (initialOffset - items.single { it.key == "old-5" }.offset).toFloat(), 2f)
        }
        assertEquals("Delivery metadata must not appear while the flight still owns the target", 0, metadataPixels())
        ui.runOnIdle { harness.motion.cancel() }
        ui.mainClock.advanceTimeBy(32)
        ui.waitForIdle()
        assertTrue("Delivery metadata appears once the row lands", metadataPixels() > 100)
    }

    @Test fun remoteHistoryWithoutALocalBeginNeverMovesTheReader() {
        val harness = prepare()
        var index = 0
        var offset = 0
        ui.runOnIdle {
            index = harness.list.firstVisibleItemIndex
            offset = harness.list.firstVisibleItemScrollOffset
            harness.rows.add(Row("remote-history", 150.dp))
        }
        ui.mainClock.advanceTimeBy(350)
        ui.waitForIdle()
        ui.runOnIdle {
            assertEquals(index, harness.list.firstVisibleItemIndex)
            assertEquals(offset, harness.list.firstVisibleItemScrollOffset)
            assertEquals(null, harness.motion.messageId)
        }
    }

    private fun metadataPixels(): Int {
        val bitmap = ui.onNodeWithTag("growth-list").captureToImage().asAndroidBitmap()
        var count = 0
        for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
            if (bitmap.getPixel(x, y) == Color.Magenta.toArgb()) count++
        }
        return count
    }
}
