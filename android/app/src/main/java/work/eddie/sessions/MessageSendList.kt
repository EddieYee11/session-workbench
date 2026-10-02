package work.eddie.sessions

import android.view.View
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.constrainHeight
import kotlin.math.roundToInt
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Wrap the complete message row, including its delivery metadata. Move the list's
 * Arrangement.spacedBy gap into trailingSpacing so no full-size gap appears on frame zero.
 * Children are measured at their final size; only the reserved row height grows.
 */
@Composable
fun MessageSendRow(
    motion: MessageSendMotionState?,
    messageId: String,
    modifier: Modifier = Modifier,
    trailingSpacing: Dp = 0.dp,
    content: @Composable () -> Unit,
) {
    Layout(content = content, modifier = modifier.clipToBounds()) { measurables, constraints ->
        val childConstraints = constraints.copy(minHeight = 0, maxHeight = Constraints.Infinity)
        val children = measurables.map { it.measure(childConstraints) }
        val fullHeight = children.sumOf { it.height }
        val width = constraints.constrainWidth(children.maxOfOrNull { it.width } ?: 0)
        val progress = if (motion?.messageId == messageId) motion.progress else 1f
        val height = messageSendExpandedHeight(fullHeight, trailingSpacing.roundToPx(), progress)
        layout(width, constraints.constrainHeight(height)) {
            var top = 0
            children.forEach { child -> child.placeRelative(0, top); top += child.height }
        }
    }
}

/**
 * Follow only the explicit local send. Near the bottom, each new pixel of row/gap
 * growth scrolls the same number of overflowing pixels, moving earlier rows smoothly.
 * A user reading far back is taken to this local send with an animated navigation first.
 * Remote messages and history loads have no sequence and cannot move the viewport.
 */
@Composable
fun MessageSendListScroll(
    motion: MessageSendMotionState?,
    listState: LazyListState,
    targetIndex: Int?,
    active: Boolean = true,
) {
    val sequence = motion?.localSendSequence
    val view = LocalView.current
    var lastLocalTarget by remember(listState) { mutableStateOf<Int?>(null) }
    LaunchedEffect(sequence, targetIndex, active) {
        if (!active || motion == null) {
            lastLocalTarget = null
            return@LaunchedEffect
        }
        suspend fun fillOverflow(index: Int) {
            // A layoutInfo snapshot is written during LazyColumn measure. Resume
            // in the next main-loop turn before scrollBy's synchronous remeasure.
            awaitMessageSendLayoutTurn(view)
            val layout = listState.layoutInfo
            val target = layout.visibleItemsInfo.firstOrNull { it.index == index }
            if (target != null) {
                val overflow = messageSendViewportOverflow(target.offset, target.size, layout.viewportEndOffset, layout.afterContentPadding)
                if (overflow > .5f) listState.scrollBy(overflow)
            }
        }
        if (sequence == null) {
            // Completion replaces the expanding row by its final full height.
            // Only a preceding local send is allowed this final settlement pass.
            lastLocalTarget?.let { fillOverflow(it) }
            lastLocalTarget = null
            return@LaunchedEffect
        }
        if (targetIndex == null) return@LaunchedEffect
        lastLocalTarget = targetIndex
        val info = listState.layoutInfo
        if (targetIndex !in info.visibleItemsInfo.map { it.index }) {
            // The collapsed row should land at the bottom, leaving room for its
            // measured content to enter with the common 250ms progress.
            val viewport = (info.viewportEndOffset - info.viewportStartOffset).coerceAtLeast(1)
            listState.animateScrollToItem(targetIndex, -viewport)
        }
        // React to the measured row expansion immediately, rather than applying
        // last frame's height and visibly lagging behind the overlay's progress.
        snapshotFlow { motion.localSendSequence to listState.layoutInfo }
            .takeWhile { it.first == sequence }
            .collect { fillOverflow(targetIndex) }
    }
}

private suspend fun awaitMessageSendLayoutTurn(view: View) = suspendCancellableCoroutine<Unit> { continuation ->
    val commit = Runnable { if (continuation.isActive) continuation.resume(Unit) }
    view.post(commit)
    continuation.invokeOnCancellation { view.removeCallbacks(commit) }
}

internal fun messageSendExpandedHeight(contentHeight: Int, spacing: Int, progress: Float): Int =
    ((contentHeight.coerceAtLeast(0) + spacing.coerceAtLeast(0)).toFloat() * progress.coerceIn(0f, 1f)).roundToInt()

internal fun messageSendViewportOverflow(offset: Int, height: Int, viewportEnd: Int, afterPadding: Int): Float =
    (offset.toLong() + height.coerceAtLeast(0) + afterPadding.coerceAtLeast(0) - viewportEnd).coerceAtLeast(0L).toFloat()
