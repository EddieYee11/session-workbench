package work.eddie.sessions

import android.animation.ValueAnimator
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.View
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntSize
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.delay

/** A design reference only; independently implemented with Compose, without Telegram code. */
val MessageSendEasing = CubicBezierEasing(.1991947291f, .01064453125f, .2792093704f, .91025390625f)
const val MessageSendDurationMillis = 250

enum class MessageSendContentKind { Text, RichText, Code, Image, Attachment }
enum class MessageSendTransitionKind { Morph, Fallback }
enum class MessageSendCoordinateSpace { Root, Screen }
val LocalMessageSendMotion = compositionLocalOf<MessageSendMotionState?> { null }
private val MessageRichSyntax = Regex("(?m)^\\s*(?:#{1,6}\\s|>\\s|[-*+]\\s|\\d+\\.\\s)|```|~~~|`[^`]+`|!\\[[^]]*]\\(|\\[[^]]+]\\(|\\*\\*|__")

/** Layout topology must agree; otherwise preserve the real rich bubble and animate its layer. */
fun classifyMessageSendTransition(
    text: String,
    sourceLines: Int,
    targetLines: Int,
    contentKind: MessageSendContentKind = MessageSendContentKind.Text,
    sameLineBreaks: Boolean = true,
    sameText: Boolean = true,
    sourceFullyVisible: Boolean = true,
): MessageSendTransitionKind {
    return if (contentKind != MessageSendContentKind.Text || sourceLines !in 1..10 || targetLines !in 1..10 ||
        !sameLineBreaks || !sameText || !sourceFullyVisible || MessageRichSyntax.containsMatchIn(text)
    ) MessageSendTransitionKind.Fallback else MessageSendTransitionKind.Morph
}

internal data class SendTextGeometry(
    val layout: TextLayoutResult,
    val style: TextStyle,
)

internal data class SendComposerGeometry(
    val textBounds: Rect? = null,
    val backgroundBounds: Rect? = null,
    val text: SendTextGeometry? = null,
    val backgroundColor: Color = Color.Transparent,
    val cornerRadius: Dp = 24.dp,
    val viewportBounds: Rect? = null,
    val textSpace: MessageSendCoordinateSpace = MessageSendCoordinateSpace.Root,
    val backgroundSpace: MessageSendCoordinateSpace = MessageSendCoordinateSpace.Root,
)

internal data class SendTargetGeometry(
    val bubbleBounds: Rect? = null,
    val textBounds: Rect? = null,
    val text: SendTextGeometry? = null,
    val color: Color = Color.Transparent,
    val cornerRadius: Dp = 28.dp,
    val kind: MessageSendContentKind = MessageSendContentKind.Text,
    val bubbleSpace: MessageSendCoordinateSpace = MessageSendCoordinateSpace.Root,
    val textSpace: MessageSendCoordinateSpace = MessageSendCoordinateSpace.Root,
)

internal data class LocalSendTransition(
    val sequence: Long,
    val messageId: String,
    val text: String,
    val source: SendComposerGeometry,
    val target: SendTargetGeometry = SendTargetGeometry(),
    val forceFallback: Boolean = false,
) {
    val transitionKind: MessageSendTransitionKind
        get() {
            if (forceFallback) return MessageSendTransitionKind.Fallback
            val from = source.text?.layout
            val to = target.text?.layout
            val sameBreaks = from != null && to != null && from.lineCount == to.lineCount &&
                (0 until from.lineCount).all {
                    from.getLineStart(it) == to.getLineStart(it) && from.getLineEnd(it) == to.getLineEnd(it) &&
                        from.getParagraphDirection(from.getLineStart(it)) == to.getParagraphDirection(to.getLineStart(it))
                }
            return classifyMessageSendTransition(
                text, from?.lineCount ?: 0, to?.lineCount ?: 0, target.kind, sameBreaks,
                sameText = from?.layoutInput?.text?.text == text && to?.layoutInput?.text?.text == text &&
                    to.layoutInput.text.spanStyles.isEmpty() && to.layoutInput.text.paragraphStyles.isEmpty(),
                sourceFullyVisible = from != null && !from.hasVisualOverflow &&
                    messageSendSourceFullyVisible(from.size, source.textBounds, source.viewportBounds),
            )
        }

    val ready: Boolean
        get() = target.bubbleBounds.isUsable() &&
            (target.kind != MessageSendContentKind.Text || target.text != null) &&
            (transitionKind == MessageSendTransitionKind.Fallback ||
                (source.textBounds.isUsable() && target.textBounds.isUsable() && target.text != null))
}

/**
 * UI-owned and deliberately not saveable: only an explicit local begin animates.
 * Update measurement callbacks freely; history, refresh and server replay cannot begin a send.
 * Capture begin before clearing the composer; retarget only if the server assigns another ID.
 */
@Stable
class MessageSendMotionState {
    internal var transition by mutableStateOf<LocalSendTransition?>(null)
        private set
    internal var progress by mutableFloatStateOf(1f)
        private set
    private var composer = SendComposerGeometry()
    private val composerSources = linkedMapOf<Any, SendComposerGeometry>()
    private var sequence = 0L
    private var enabled = true
    internal var animating = false
        private set

    val messageId: String? get() = transition?.messageId
    val localSendSequence: Long? get() = transition?.sequence

    fun updateComposerBounds(
        textBoundsInRoot: Rect,
        backgroundBoundsInRoot: Rect? = null,
        viewportBounds: Rect? = null,
        coordinateSpace: MessageSendCoordinateSpace = MessageSendCoordinateSpace.Root,
        sourceKey: Any? = null,
    ) {
        updateComposer(sourceKey) { current -> current.copy(textBounds = textBoundsInRoot, viewportBounds = viewportBounds,
            textSpace = coordinateSpace,
            backgroundBounds = backgroundBoundsInRoot ?: current.backgroundBounds,
            backgroundSpace = if (backgroundBoundsInRoot != null) coordinateSpace else current.backgroundSpace) }
    }

    fun updateComposerBackgroundBounds(bounds: Rect, coordinateSpace: MessageSendCoordinateSpace = MessageSendCoordinateSpace.Root,
        color: Color = Color.Unspecified, sourceKey: Any? = null) {
        updateComposer(sourceKey) { current -> current.copy(backgroundBounds = bounds, backgroundSpace = coordinateSpace,
            backgroundColor = color.takeIf { it != Color.Unspecified } ?: current.backgroundColor) }
    }

    fun updateComposerLayout(
        layout: TextLayoutResult,
        style: TextStyle,
        backgroundColor: Color = Color.Unspecified,
        cornerRadius: Dp = 24.dp,
        sourceKey: Any? = null,
    ) {
        updateComposer(sourceKey) { current -> current.copy(text = SendTextGeometry(layout, style),
            backgroundColor = backgroundColor.takeIf { it != Color.Unspecified } ?: current.backgroundColor, cornerRadius = cornerRadius) }
    }

    fun begin(messageId: String, text: String, sourceKey: Any? = null): Boolean {
        return beginLocal(messageId, text, false, sourceKey)
    }

    /** Voice hand-offs have no visible text source; animate their real destination row. */
    fun beginFallback(messageId: String, text: String): Boolean {
        return beginLocal(messageId, text, true, null)
    }

    private fun beginLocal(messageId: String, text: String, forceFallback: Boolean, sourceKey: Any?): Boolean {
        if (!enabled || messageId.isBlank() || text.isBlank()) return false
        sequence += 1
        val source = if (sourceKey == null) composer else composerSources[sourceKey] ?: SendComposerGeometry()
        transition = LocalSendTransition(sequence, messageId, text, source, forceFallback = forceFallback)
        progress = 0f
        animating = false
        return true
    }

    /** Never text-match a server message: bind only the ID from this local send's receipt. */
    fun retarget(localMessageId: String, acceptedMessageId: String) {
        val current = transition ?: return
        if (current.messageId == localMessageId && acceptedMessageId.isNotBlank()) {
            transition = current.copy(messageId = acceptedMessageId)
        }
    }

    fun updateTargetBounds(messageId: String, bubbleBoundsInRoot: Rect? = null, textBoundsInRoot: Rect? = null,
        coordinateSpace: MessageSendCoordinateSpace = MessageSendCoordinateSpace.Root) {
        updateTarget(messageId) { it.copy(bubbleBounds = bubbleBoundsInRoot ?: it.bubbleBounds, textBounds = textBoundsInRoot ?: it.textBounds,
            bubbleSpace = if (bubbleBoundsInRoot != null) coordinateSpace else it.bubbleSpace,
            textSpace = if (textBoundsInRoot != null) coordinateSpace else it.textSpace) }
    }

    fun updateTargetLayout(
        messageId: String,
        layout: TextLayoutResult,
        style: TextStyle,
        bubbleColor: Color,
        contentKind: MessageSendContentKind = MessageSendContentKind.Text,
        cornerRadius: Dp = 28.dp,
    ) {
        updateTarget(messageId) {
            it.copy(text = SendTextGeometry(layout, style), color = bubbleColor, kind = contentKind, cornerRadius = cornerRadius)
        }
    }

    fun updateTargetContent(messageId: String, contentKind: MessageSendContentKind) {
        updateTarget(messageId) { it.copy(kind = contentKind) }
    }

    fun shouldHideTarget(messageId: String): Boolean {
        val current = transition ?: return false
        return current.messageId == messageId && (!current.ready || current.transitionKind == MessageSendTransitionKind.Morph)
    }

    fun cancel() {
        transition = null
        progress = 1f
        animating = false
    }

    internal fun setEnabled(value: Boolean) {
        enabled = value
        if (!value) cancel()
    }

    internal fun frame(value: Float) { progress = value.coerceIn(0f, 1f) }
    internal fun start(sequence: Long) { if (transition?.sequence == sequence) animating = true }
    internal fun finish(sequence: Long) { if (transition?.sequence == sequence) cancel() }

    private fun updateTarget(messageId: String, block: (SendTargetGeometry) -> SendTargetGeometry) {
        val current = transition ?: return
        if (current.messageId != messageId) return
        val next = block(current.target)
        if (next != current.target) transition = current.copy(target = next)
    }

    private fun updateComposer(sourceKey: Any?, block: (SendComposerGeometry) -> SendComposerGeometry) {
        if (sourceKey == null) composer = block(composer)
        else {
            val previous = composerSources.remove(sourceKey) ?: SendComposerGeometry()
            composerSources[sourceKey] = block(previous)
            // Modal source tokens are remembered by their editor, not retained indefinitely.
            while (composerSources.size > 8) composerSources.remove(composerSources.keys.first())
        }
    }
}

@Composable
fun rememberMessageSendMotionState(active: Boolean = true): MessageSendMotionState {
    val state = remember { MessageSendMotionState() }
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var resumed by remember(lifecycle) { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    var motionAllowed by remember { mutableStateOf(ValueAnimator.areAnimatorsEnabled()) }
    DisposableEffect(context, lifecycle, state) {
        val motionObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { motionAllowed = ValueAnimator.areAnimatorsEnabled() }
        }
        val lifecycleObserver = LifecycleEventObserver { _, _ ->
            resumed = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            motionAllowed = ValueAnimator.areAnimatorsEnabled()
            if (!resumed) state.setEnabled(false)
        }
        context.contentResolver.registerContentObserver(
            Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, motionObserver,
        )
        lifecycle.addObserver(lifecycleObserver)
        onDispose {
            context.contentResolver.unregisterContentObserver(motionObserver)
            lifecycle.removeObserver(lifecycleObserver)
            state.cancel()
        }
    }
    SideEffect { state.setEnabled(active && resumed && motionAllowed) }
    return state
}

/** Apply to the whole target bubble; metadata/reactions remain separate from the flying text. */
@Composable
fun Modifier.messageSendMotionTarget(state: MessageSendMotionState, messageId: String): Modifier {
    val density = LocalDensity.current.density
    return graphicsLayer {
        val send = state.transition?.takeIf { it.messageId == messageId }
        if (send == null) {
            alpha = 1f; scaleX = 1f; scaleY = 1f; translationY = 0f
        } else if (!send.ready || send.transitionKind == MessageSendTransitionKind.Morph) {
            alpha = 0f; scaleX = 1f; scaleY = 1f; translationY = 0f
        } else {
            val p = state.progress
            alpha = p
            scaleX = .975f + .025f * p
            scaleY = scaleX
            translationY = 20f * density * (1f - p)
        }
    }
}

/** Keep delivery labels, reactions and task metadata out of the flight; reveal on landing. */
fun Modifier.messageSendMetadata(state: MessageSendMotionState?, messageId: String): Modifier = graphicsLayer {
    alpha = if (state?.messageId == messageId) 0f else 1f
}

/** Screen coordinates allow a modal-window composer to feed the main-window overlay. */
@Composable
fun Modifier.messageSendComposerBounds(state: MessageSendMotionState?, background: Boolean = false,
    backgroundColor: Color = Color.Unspecified, sourceKey: Any? = null): Modifier {
    val view = LocalView.current
    return onGloballyPositioned {
        if (state == null) return@onGloballyPositioned
        val bounds = it.messageSendBoundsOnScreen(view)
        if (background) state.updateComposerBackgroundBounds(bounds, MessageSendCoordinateSpace.Screen, backgroundColor, sourceKey)
        else state.updateComposerBounds(bounds, viewportBounds = it.messageSendViewportOnScreen(view),
            coordinateSpace = MessageSendCoordinateSpace.Screen, sourceKey = sourceKey)
    }
}

@Composable
fun Modifier.messageSendTargetBounds(state: MessageSendMotionState?, messageId: String, text: Boolean = false): Modifier {
    val view = LocalView.current
    return onGloballyPositioned {
        if (text) state?.updateTargetBounds(messageId, textBoundsInRoot = it.messageSendBoundsOnScreen(view),
            coordinateSpace = MessageSendCoordinateSpace.Screen)
        else state?.updateTargetBounds(messageId, bubbleBoundsInRoot = it.messageSendBoundsOnScreen(view),
            coordinateSpace = MessageSendCoordinateSpace.Screen)
    }
}

/** Place once in the main window. Legacy root bounds and cross-window screen bounds both work. */
@OptIn(ExperimentalTextApi::class)
@Composable
fun MessageSendMotionOverlay(state: MessageSendMotionState, modifier: Modifier = Modifier) {
    val send = state.transition
    val animation = remember { Animatable(1f) }
    var overlayOrigin by remember { mutableStateOf(Offset.Zero) }
    var rootScreenOffset by remember { mutableStateOf(Offset.Zero) }
    val density = LocalDensity.current
    val view = LocalView.current

    // A target may never materialize after a rejected send. It must never stay hidden.
    LaunchedEffect(send?.sequence) {
        val sequence = send?.sequence ?: return@LaunchedEffect
        delay(3_000L)
        state.finish(sequence)
    }
    LaunchedEffect(send?.sequence, send?.ready) {
        if (send == null || !send.ready) return@LaunchedEffect
        animation.snapTo(0f)
        state.start(send.sequence)
        try {
            animation.animateTo(1f, tween(MessageSendDurationMillis, easing = MessageSendEasing)) {
                state.frame(value)
            }
        } finally {
            // A zero-size/replaced target can change readiness mid-flight. Cancel
            // must release its hidden bubble too, not only normal completion.
            state.finish(send.sequence)
        }
    }

    Canvas(modifier.onGloballyPositioned {
        overlayOrigin = it.messageSendBoundsOnScreen(view).topLeft
        rootScreenOffset = overlayOrigin - it.boundsInRoot().topLeft
    }.clearAndSetSemantics { }) {
        val current = state.transition ?: return@Canvas
        if (!current.ready || current.transitionKind != MessageSendTransitionKind.Morph) return@Canvas
        val source = current.source
        val target = current.target
        val toLayout = target.text?.layout ?: return@Canvas
        val fromLayout = source.text?.layout ?: return@Canvas
        val startText = source.textBounds?.onScreen(source.textSpace, rootScreenOffset) ?: return@Canvas
        val endText = target.textBounds?.onScreen(target.textSpace, rootScreenOffset) ?: return@Canvas
        val endBubble = target.bubbleBounds?.onScreen(target.bubbleSpace, rootScreenOffset) ?: return@Canvas
        val p = state.progress
        val startBubble = source.backgroundBounds?.onScreen(source.backgroundSpace, rootScreenOffset)
            ?: startText.inflate(with(density) { 5.dp.toPx() })
        val bubble = lerpRect(startBubble, endBubble, p)
        val sourceColor = source.text.style.color.takeIf { it != Color.Unspecified } ?: Color.Black
        val targetColor = target.text.style.color.takeIf { it != Color.Unspecified } ?: Color.Black
        val bodyColor = lerp(source.backgroundColor, target.color, p)
        val radius = with(density) { source.cornerRadius.toPx() * (1f - p) + target.cornerRadius.toPx() * p }
        // The measured input surface may include attachment/send buttons. Keep
        // those original controls uncovered at the source; only the editable
        // background opens into the whole bubble. No control pixels are copied.
        val inset = with(density) { 5.dp.toPx() }
        val editableBackground = Rect(maxOf(startBubble.left, startText.left - inset), startBubble.top,
            minOf(startBubble.right, startText.right + inset), startBubble.bottom)
        val reveal = lerpRect(editableBackground, endBubble, p)
        clipRect(reveal.left - overlayOrigin.x, reveal.top - overlayOrigin.y,
            reveal.right - overlayOrigin.x, reveal.bottom - overlayOrigin.y) {
            drawRoundRect(
                color = bodyColor,
                topLeft = bubble.topLeft - overlayOrigin,
                size = Size(bubble.width, bubble.height),
                cornerRadius = CornerRadius(radius, radius),
            )
        }
        val sourceFont = fromLayout.layoutInput.style.fontSize
        val targetFont = toLayout.layoutInput.style.fontSize
        val fontRatio = if (sourceFont.isSp && targetFont.isSp && targetFont.value > 0f) sourceFont.value / targetFont.value else 1f
        val scale = fontRatio * (1f - p) + p
        // Layout line heights need not scale with font size (e.g. 15/22 -> 16/24).
        // Anchor each real baseline and visual line-left independently. This also
        // preserves RTL alignment and avoids a first-frame vertical text jump.
        for (line in 0 until toLayout.lineCount) {
            val sourceLeft = startText.left + fromLayout.getLineLeft(line)
            val targetLeft = endText.left + toLayout.getLineLeft(line)
            val sourceBaseline = startText.top + fromLayout.getLineBaseline(line)
            val targetBaseline = endText.top + toLayout.getLineBaseline(line)
            val position = Offset(
                sourceLeft * (1f - p) + targetLeft * p - toLayout.getLineLeft(line) * scale,
                sourceBaseline * (1f - p) + targetBaseline * p - toLayout.getLineBaseline(line) * scale,
            ) - overlayOrigin
            withTransform({
                translate(position.x, position.y)
                scale(scale, scale, pivot = Offset.Zero)
            }) {
                clipRect(top = toLayout.getLineTop(line), bottom = toLayout.getLineBottom(line)) {
                    drawText(toLayout, color = lerp(sourceColor, targetColor, p), topLeft = Offset.Zero)
                }
            }
        }
    }
}

/** A scrolled/clipped BasicTextField has no trustworthy glyph origin; use the real bubble fallback. */
internal fun messageSendSourceFullyVisible(size: IntSize, bounds: Rect?, viewport: Rect?): Boolean {
    if (!bounds.isUsable()) return false
    val actual = bounds!!
    if (size.width > actual.width + 1f || size.height > actual.height + 1f) return false
    val clip = viewport ?: actual
    return clip.isUsable() && actual.left >= clip.left - 1f && actual.top >= clip.top - 1f &&
        actual.right <= clip.right + 1f && actual.bottom <= clip.bottom + 1f
}

private fun Rect.onScreen(space: MessageSendCoordinateSpace, rootOffset: Offset): Rect =
    if (space == MessageSendCoordinateSpace.Screen) this else translate(rootOffset)

private fun View.messageSendWindowOrigin(): Offset {
    val screen = IntArray(2)
    val window = IntArray(2)
    getLocationOnScreen(screen)
    getLocationInWindow(window)
    return Offset((screen[0] - window[0]).toFloat(), (screen[1] - window[1]).toFloat())
}

/** Entire node bounds, unaffected by LazyColumn/window viewport clipping. */
fun LayoutCoordinates.messageSendBoundsOnScreen(view: View): Rect {
    if (!isAttached) return Rect.Zero
    val origin = view.messageSendWindowOrigin()
    val width = size.width.toFloat()
    val height = size.height.toFloat()
    val points = listOf(Offset.Zero, Offset(width, 0f), Offset(0f, height), Offset(width, height))
        .map { localToWindow(it) + origin }
    return Rect(points.minOf { it.x }, points.minOf { it.y }, points.maxOf { it.x }, points.maxOf { it.y })
}

fun LayoutCoordinates.messageSendViewportOnScreen(view: View): Rect =
    if (isAttached) boundsInWindow().translate(view.messageSendWindowOrigin()) else Rect.Zero

private fun Rect?.isUsable(): Boolean = this != null && width > 0f && height > 0f &&
    left.isFinite() && top.isFinite() && right.isFinite() && bottom.isFinite()

private fun lerpRect(from: Rect, to: Rect, p: Float) = Rect(
    from.left * (1f - p) + to.left * p,
    from.top * (1f - p) + to.top * p,
    from.right * (1f - p) + to.right * p,
    from.bottom * (1f - p) + to.bottom * p,
)

/**
 * Measure the entire layout, not its viewport-clipped part. boundsInRoot clips a
 * partially visible LazyColumn row and would otherwise shrink the flying bubble.
 * The four transformed corners also preserve real geometry during item placement.
 */
fun LayoutCoordinates.messageSendBoundsInRoot(): Rect {
    if (!isAttached) return Rect.Zero
    val width = size.width.toFloat()
    val height = size.height.toFloat()
    val a = localToRoot(Offset.Zero)
    val b = localToRoot(Offset(width, 0f))
    val c = localToRoot(Offset(0f, height))
    val d = localToRoot(Offset(width, height))
    return Rect(
        minOf(a.x, b.x, c.x, d.x), minOf(a.y, b.y, c.y, d.y),
        maxOf(a.x, b.x, c.x, d.x), maxOf(a.y, b.y, c.y, d.y),
    )
}
