package work.eddie.sessions

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Forward
import androidx.compose.material.icons.outlined.Reply
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.sign

internal enum class MessageSwipeIntent { Reply, Forward }
internal enum class MessageSwipeAxis { Pending, Horizontal, Vertical, TextSelection }

/** Commit uses the release position, so reversing an armed swipe never sends an action. */
internal fun messageSwipeIntent(offset: Float, threshold: Float): MessageSwipeIntent? {
    if (!offset.isFinite() || threshold <= 0f || !threshold.isFinite()) return null
    return when {
        offset >= threshold -> MessageSwipeIntent.Reply
        offset <= -threshold -> MessageSwipeIntent.Forward
        else -> null
    }
}

internal fun messageSwipeAxis(x: Float, y: Float, elapsed: Long, slop: Float, longPress: Long): MessageSwipeAxis = when {
    elapsed >= longPress -> MessageSwipeAxis.TextSelection
    abs(y) >= slop && abs(y) >= abs(x) -> MessageSwipeAxis.Vertical
    abs(x) >= slop && abs(x) > abs(y) * 1.3f -> MessageSwipeAxis.Horizontal
    else -> MessageSwipeAxis.Pending
}

/** A gesture gets exactly one threshold cue, including repeated crossing or reversal. */
internal class MessageSwipeFeedback {
    private var emitted = false
    fun cross(offset: Float, threshold: Float): Boolean {
        if (emitted || messageSwipeIntent(offset, threshold) == null) return false
        emitted = true
        return true
    }
}

/**
 * Right drag replies; left drag forwards. It never dismisses or removes a message.
 * Long presses remain available to selectable Compose and native Markdown text.
 * Callers can also disable swiping while a text selection or another editor is active.
 */
@Composable
fun MessageSwipeActions(
    message: JSONObject,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onReply: (JSONObject) -> Unit,
    onForward: (JSONObject) -> Unit,
    content: @Composable () -> Unit
) {
    val key = message.optString("id").ifBlank { message.optString("message_id") }.ifBlank { message }
    var offset by remember(key) { mutableFloatStateOf(0f) }
    var dragging by remember(key) { mutableStateOf(false) }
    val threshold = with(LocalDensity.current) { 56.dp.toPx() }
    val reply by rememberUpdatedState(onReply)
    val forward by rememberUpdatedState(onForward)
    val currentMessage by rememberUpdatedState(message)
    val haptics = rememberComHaptics()
    val translation by animateFloatAsState(offset, if (dragging) snap() else Motion.Gentle, label = "消息回弹")
    val intent = messageSwipeIntent(offset, threshold)
    val progress = (abs(translation) / threshold).coerceIn(0f, 1f)
    val badgeScale by animateFloatAsState(if (intent != null) 1.2f else .78f + progress * .22f, Motion.Pop, label = "滑动动作提示")
    fun invoke(action: MessageSwipeIntent) {
        if (action == MessageSwipeIntent.Reply) reply(currentMessage) else forward(currentMessage)
    }
    val gestures = if (!enabled) Modifier else Modifier.pointerInput(key, threshold) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
            val feedback = MessageSwipeFeedback()
            var axis = MessageSwipeAxis.Pending
            var released = false
            var cancelled = false
            offset = 0f
            dragging = false
            try {
                while (true) {
                    val event = awaitPointerEvent(PointerEventPass.Initial)
                    val change = event.changes.firstOrNull { it.id == down.id } ?: break
                    if (event.changes.count { it.pressed } > 1 || change.isConsumed) {
                        cancelled = true
                        break
                    }
                    if (!change.pressed) {
                        released = true
                        if (axis == MessageSwipeAxis.Horizontal) change.consume()
                        break
                    }
                    val delta = change.position - down.position
                    if (axis == MessageSwipeAxis.Pending) {
                        axis = messageSwipeAxis(delta.x, delta.y, change.uptimeMillis - down.uptimeMillis,
                            viewConfiguration.touchSlop, viewConfiguration.longPressTimeoutMillis)
                    }
                    if (axis == MessageSwipeAxis.Vertical || axis == MessageSwipeAxis.TextSelection) break
                    if (axis == MessageSwipeAxis.Horizontal) {
                        // Initial pass intercepts an intentional horizontal drag before
                        // AndroidView text can capture it, while leaving presses/vertical
                        // movement untouched for selection and the parent scrolling list.
                        change.consume()
                        dragging = true
                        val magnitude = abs(delta.x)
                        offset = sign(delta.x) * (if (magnitude <= threshold) magnitude
                            else threshold + (magnitude - threshold) * .22f).coerceAtMost(threshold * 1.55f)
                        if (feedback.cross(offset, threshold)) haptics(HapticCue.Selection)
                    }
                }
                if (released && !cancelled && axis == MessageSwipeAxis.Horizontal) {
                    messageSwipeIntent(offset, threshold)?.let(::invoke)
                }
            } finally {
                dragging = false
                offset = 0f
            }
        }
    }
    Box(modifier.then(gestures).testTag("message-swipe-${message.optString("id")}").semantics {
        if (enabled) customActions = listOf(
            CustomAccessibilityAction("回复消息") { haptics(HapticCue.Selection); invoke(MessageSwipeIntent.Reply); true },
            CustomAccessibilityAction("在当前对话引用消息") { haptics(HapticCue.Selection); invoke(MessageSwipeIntent.Forward); true }
        )
    }) {
        if (progress > .01f) {
            val isReply = translation > 0f
            Box(Modifier.align(if (isReply) Alignment.CenterStart else Alignment.CenterEnd)
                .padding(horizontal = 16.dp).size(32.dp)
                .graphicsLayer { alpha = progress; scaleX = badgeScale; scaleY = badgeScale }
                .background(if (isReply) PiSoft else CompanionGlow, CircleShape), contentAlignment = Alignment.Center) {
                Icon(if (isReply) Icons.Outlined.Reply else Icons.Outlined.Forward,
                    if (isReply) "松手回复" else "松手引用", Modifier.size(19.dp), tint = if (isReply) PiGreen else CompanionBlue)
            }
        }
        Box(Modifier.graphicsLayer { translationX = translation }) { content() }
    }
}

/** Draft context preview; closing it only clears the draft reference. */
@Composable
fun MessageReferencePreview(reference: JSONObject, onDismiss: () -> Unit) {
    val forwarding = reference.optString("mode") == "forward"
    val color = if (forwarding) CompanionBlue else PiGreen
    Surface(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 5.dp)
        .testTag("message-reference-preview"), color = if (forwarding) CompanionGlow else PiSoft,
        shape = RoundedCornerShape(14.dp)) {
        Row(Modifier.padding(start = 12.dp, top = 7.dp, bottom = 7.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(3.dp).height(36.dp).background(color, CircleShape))
            Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                Text((if (forwarding) "引用" else "回复") + " · " + reference.optString("author").ifBlank { "这条消息" },
                    color = color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(reference.optString("text").take(1000), color = Muted, fontSize = 12.sp, lineHeight = 17.sp,
                    maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            IconButton(onClick = onDismiss, modifier = Modifier.size(40.dp)) {
                Icon(Icons.Outlined.Close, "取消${if (forwarding) "引用" else "回复"}", Modifier.size(18.dp), tint = Muted)
            }
        }
    }
}
