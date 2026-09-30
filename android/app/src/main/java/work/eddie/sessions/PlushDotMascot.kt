package work.eddie.sessions

// User-supplied native component from Downloads/plush-mascot/android/PlushDotMascot.kt.
// Integration changes: package and configurable cached texture resolution for small avatars.

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.updateTransition
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitTouchSlopOrCancellation
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Canvas as GraphicsCanvas
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.atan2
import kotlin.math.exp
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/** Business state belongs to the host. Success and Error never dismiss themselves. */
enum class PlushDotState { Idle, Listening, Thinking, Working, Success, Error, Sleep, Curious }

/** Geometry density only; both qualities retain real, individual fuzzy-edge and surface fibers. */
enum class PlushFurQuality { Standard, High }

/**
 * Round periwinkle plush companion: cached procedural fur, locally deformed by a soft-body mesh.
 * Uses Android Canvas.drawBitmapMesh; no network, shader, external asset, or Material dependency.
 *
 * @param gaze Normalized x/y in [-1, 1]; invalid values are sanitized. Local pointer overrides it.
 * @param reducedMotion Stops autonomous/inertial motion; deliberate dragging remains direct.
 * @param isAnimationActive False for background or off-screen instances. Cancels repeating work.
 * @param onTap Optional real app action. Null omits button semantics; dragging remains optional.
 * @param showStatusMark Show the small top-left status badge, including a lime idle light.
 * @param furQuality Geometry is remembered and only rebuilt when this parameter changes.
 */
@Composable
fun PlushDotMascot(
    state: PlushDotState = PlushDotState.Idle,
    modifier: Modifier = Modifier,
    gaze: Offset = Offset.Zero,
    reducedMotion: Boolean = false,
    isAnimationActive: Boolean = true,
    onTap: (() -> Unit)? = null,
    showStatusMark: Boolean = true,
    furQuality: PlushFurQuality = PlushFurQuality.High,
    description: String = "蓝紫绒伙伴",
    stateLabel: String = state.defaultLabel(),
    showBeret: Boolean = true,
    dragEnabled: Boolean = true,
    textureResolution: Int = 672,
) {
    val windowFocused = LocalWindowInfo.current.isWindowFocused
    val active = isAnimationActive && windowFocused
    val moving = active && !reducedMotion
    val textureSize = textureResolution.coerceIn(224, 1024)
    val artwork = remember(furQuality, showBeret, textureSize) { PlushArtwork(furQuality, showBeret, textureSize) }
    val softBody = remember { PlushSoftBody() }
    val bodyFrame = remember { PlushFrame() }
    val dragRevision = remember { mutableIntStateOf(0) }
    val seconds = remember { mutableFloatStateOf(0f) }
    val blink = remember { Animatable(1f) }
    val press = remember { Animatable(0f) }
    val hatBounce = remember { Animatable(0f) }
    var taps by remember { mutableIntStateOf(0) }
    val handledTaps = remember { mutableIntStateOf(0) }
    var pointerGaze by remember { mutableStateOf<Offset?>(null) }

    // Frame state is read in drawing only. No per-frame recomposition or geometry regeneration.
    LaunchedEffect(moving) {
        if (!moving) return@LaunchedEffect
        var lastFrame = 0L
        while (isActive) {
            withFrameNanos { now ->
                if (lastFrame != 0L) {
                    val dt = ((now - lastFrame) / 1_000_000_000f).coerceIn(0f, 0.05f)
                    seconds.floatValue = (seconds.floatValue + dt) % 3600f
                    softBody.step(dt)
                }
                lastFrame = now
            }
        }
    }
    LaunchedEffect(moving, state) {
        blink.snapTo(1f)
        if (!moving || state == PlushDotState.Sleep) return@LaunchedEffect
        while (isActive) {
            delay(Random.nextLong(2_900L, 5_700L))
            blink.animateTo(0.07f, tween(78))
            blink.animateTo(1f, tween(138))
        }
    }
    LaunchedEffect(taps, moving) {
        val freshTap = taps != handledTaps.intValue
        handledTaps.intValue = taps
        if (!moving || !freshTap) {
            press.snapTo(0f)
            hatBounce.snapTo(0f)
            return@LaunchedEffect
        }
        // New taps cancel old trajectories instead of queuing up an animation backlog.
        coroutineScope {
            launch {
                press.snapTo(1f)
                press.animateTo(0f, spring(dampingRatio = 0.47f, stiffness = 260f))
            }
            launch {
                hatBounce.snapTo(0f)
                delay(42)
                hatBounce.snapTo(1f)
                hatBounce.animateTo(0f, spring(dampingRatio = 0.39f, stiffness = 190f))
            }
        }
    }
    LaunchedEffect(active, reducedMotion, dragEnabled) {
        if (!active || !dragEnabled || reducedMotion) {
            softBody.reset()
            dragRevision.intValue++
        }
        if (!moving) pointerGaze = null
    }

    val gazeTarget = (if (moving) pointerGaze else null) ?: gaze
    val gazeX = animateFloatAsState(
        gazeTarget.x.safeGaze(), if (moving) tween(190) else snap(), label = "Plush gaze X",
    )
    val gazeY = animateFloatAsState(
        gazeTarget.y.safeGaze(), if (moving) tween(190) else snap(), label = "Plush gaze Y",
    )
    val expression = updateTransition(state, label = "Plush expression")
    val eyeL = expression.animateFloat(
        transitionSpec = { if (moving) tween(300, easing = FastOutSlowInEasing) else snap() },
        label = "Left capsule",
    ) { it.pose().eyeL }
    val eyeR = expression.animateFloat(
        transitionSpec = { if (moving) tween(300, easing = FastOutSlowInEasing) else snap() },
        label = "Right capsule",
    ) { it.pose().eyeR }
    val happy = expression.animateFloat(
        transitionSpec = { if (moving) tween(270) else snap() }, label = "Happy eyes",
    ) { if (it == PlushDotState.Success) 1f else 0f }
    val tilt = expression.animateFloat(
        transitionSpec = { if (moving) spring(dampingRatio = 0.62f, stiffness = 105f) else snap() },
        label = "Soft head tilt",
    ) { it.pose().tilt }
    val hatTilt = expression.animateFloat(
        transitionSpec = { if (moving) spring(dampingRatio = 0.48f, stiffness = 65f) else snap() },
        label = "Delayed beret tilt",
    ) { it.pose().tilt }
    val lift = expression.animateFloat(
        transitionSpec = { if (moving) spring(dampingRatio = 0.64f, stiffness = 115f) else snap() },
        label = "Body lift",
    ) { it.pose().lift }
    val wide = expression.animateFloat(
        transitionSpec = { if (moving) spring(dampingRatio = 0.58f, stiffness = 150f) else snap() },
        label = "Plush width",
    ) { it.pose().wide }
    val tall = expression.animateFloat(
        transitionSpec = { if (moving) spring(dampingRatio = 0.58f, stiffness = 150f) else snap() },
        label = "Plush height",
    ) { it.pose().tall }
    val glanceX = expression.animateFloat(
        transitionSpec = { if (moving) tween(300) else snap() }, label = "Expression glance X",
    ) { it.pose().lookX }
    val glanceY = expression.animateFloat(
        transitionSpec = { if (moving) tween(300) else snap() }, label = "Expression glance Y",
    ) { it.pose().lookY }

    val pointerModifier = if (moving) Modifier.pointerInput(moving) {
        awaitPointerEventScope {
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Initial)
                if (event.type == PointerEventType.Exit || event.type == PointerEventType.Release) {
                    pointerGaze = null
                } else if (!softBody.grabbing) {
                    event.changes.firstOrNull()?.let { change ->
                        // Observe only: never consume parent scroll or drag gestures.
                        pointerGaze = Offset(
                            (change.position.x / size.width.coerceAtLeast(1) * 2f - 1f).safeGaze(),
                            (change.position.y / size.height.coerceAtLeast(1) * 2f - 1f).safeGaze(),
                        )
                    }
                }
            }
        }
    } else Modifier
    // A drag must start on the plush. Slop belongs to Compose, so ordinary taps and
    // parent scrolling remain cancellable; once acquired, dragging consumes movement.
    val dragModifier = if (active && dragEnabled) Modifier.pointerInput(reducedMotion, active) {
        try {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                val localDown = bodyFrame.local(down.position)
                if (!artwork.contains(softBody.restPoint(localDown))) return@awaitEachGesture
                val frameAtGrab = bodyFrame.copy()
                var acquired = false
                val start = awaitTouchSlopOrCancellation(down.id) { change, _ ->
                    softBody.begin(softBody.restPoint(localDown))
                    softBody.move(frameAtGrab.local(change.position) - localDown, reducedMotion)
                    pointerGaze = null
                    dragRevision.intValue++
                    acquired = true
                    change.consume()
                }
                if (start != null && acquired) {
                    val completed = drag(start.id) { change ->
                        softBody.move(frameAtGrab.local(change.position) - localDown, reducedMotion)
                        dragRevision.intValue++
                        change.consume()
                    }
                    if (completed) softBody.release(reducedMotion) else softBody.reset()
                    dragRevision.intValue++
                }
            }
        } finally {
            // Pointer-input cancellation, leaving composition, loss of focus or pause.
            softBody.reset()
            dragRevision.intValue++
        }
    } else Modifier
    val interaction = remember { MutableInteractionSource() }
    val actionModifier = if (onTap != null) Modifier.clickable(interactionSource = interaction, indication = null, role = Role.Button) {
        if (moving) taps++
        onTap()
    } else Modifier

    Canvas(
        modifier = modifier.size(240.dp).then(pointerModifier).then(dragModifier).then(actionModifier).semantics {
            contentDescription = description
            stateDescription = stateLabel
        },
    ) {
        val unit = min(size.width, size.height) / 320f
        if (!unit.isFinite() || unit <= 0f) return@Canvas
        dragRevision.intValue // Drawing observes direct drag changes, including reduced motion.
        val t = if (moving) seconds.floatValue else 0f
        val pose = state.pose()
        val motionAmplitude = if (state == PlushDotState.Sleep) 0.48f else 1f
        val breath = if (moving) sin(t * 1.75f) * motionAmplitude else 0f
        val tap = if (moving) press.value else 0f
        val hatTap = if (moving) hatBounce.value else 0f
        val headTilt = if (moving) tilt.value else pose.tilt
        val softSway = if (moving && state == PlushDotState.Listening) sin(t * 2.1f) * 1.1f else 0f
        val blinkScale = if (moving) blink.value else 1f
        val eyeShift = Offset(
            (if (moving) gazeX.value else gazeTarget.x.safeGaze()) * 6f +
                (if (moving) glanceX.value else pose.lookX),
            (if (moving) gazeY.value else gazeTarget.y.safeGaze()) * 4f +
                (if (moving) glanceY.value else pose.lookY),
        )
        val bodyLift = (if (moving) lift.value else pose.lift) + breath * 3f + tap * 4f
        val bodyAngle = headTilt + softSway
        val bodyWidth = (if (moving) wide.value else pose.wide) + breath * 0.009f + tap * 0.055f
        val bodyHeight = (if (moving) tall.value else pose.tall) - breath * 0.006f - tap * 0.061f
        bodyFrame.update(size.width / 2f, size.height / 2f, unit, bodyLift, bodyAngle, bodyWidth, bodyHeight)
        translate(size.width / 2f, size.height / 2f) {
            scale(unit, unit, pivot = Offset.Zero) {
                translate(0f, 24f) {
                    // The host owns the ground shadow so it remains on the floor when
                    // this body tilts, deforms, or turns over to the other companion.
                    translate(0f, bodyLift) {
                        rotate(bodyAngle, pivot = Offset.Zero) {
                            scale(bodyWidth, bodyHeight, pivot = Offset.Zero) {
                                artwork.drawDeformedBody(this, softBody)
                                val smile = if (moving) happy.value else if (state == PlushDotState.Success) 1f else 0f
                                artwork.drawAttachedEye(this, softBody, Offset(-22f, -19f) + eyeShift,
                                    (if (moving) eyeL.value else pose.eyeL) * blinkScale, smile)
                                artwork.drawAttachedEye(this, softBody, Offset(22f, -19f) + eyeShift,
                                    (if (moving) eyeR.value else pose.eyeR) * blinkScale, smile)
                                if (showBeret) {
                                    val secondaryTilt = if (moving) {
                                        (hatTilt.value - headTilt) * 0.60f + sin(t * 1.75f - 0.40f) * 0.45f
                                    } else 0f
                                    val anchor = softBody.warp(Offset(-9f, -78f))
                                    val lag = (softBody.warp(Offset(-9f, -78f), softBody.hatPull) - anchor).limited(6f)
                                    artwork.drawBeret(this, anchor + lag,
                                        secondaryTilt - hatTap * 4.8f + (softBody.hatPull.x - softBody.pull.x) * 0.10f,
                                        -hatTap * 4.2f)
                                }
                                if (showStatusMark) artwork.drawStatus(this, state, t, moving, softBody.warp(Offset(-64f, -60f)))
                            }
                        }
                    }
                }
            }
        }
    }
}

private data class PlushPose(
    val eyeL: Float = 1f, val eyeR: Float = 1f,
    val tilt: Float = 0f, val lift: Float = 0f,
    val wide: Float = 1f, val tall: Float = 1f,
    val lookX: Float = 0f, val lookY: Float = 0f,
)

// Allocate poses once, not in the drawing loop.
private val poses = arrayOf(
    PlushPose(),
    PlushPose(1.12f, 1.12f, -4.5f, -4f, 0.99f, 1.035f, 0f, -1.5f),
    PlushPose(0.88f, 0.92f, 6f, -1f, 1.005f, 1f, 6f, -6f),
    PlushPose(0.88f, 0.88f, 0f, -1f, 1.015f, 0.99f, 0f, 1f),
    PlushPose(0.56f, 0.56f, -5.5f, -7f, 1.035f, 0.97f, 0f, -2f),
    PlushPose(0.66f, 0.84f, 4f, 3f, 1.025f, 0.965f, 0f, 3f),
    PlushPose(0.10f, 0.10f, -6f, 7f, 1.035f, 0.95f, 0f, 4f),
    PlushPose(1.14f, 0.81f, -10f, -2f, 0.985f, 1.025f, -3f, -3f),
)
private fun PlushDotState.pose(): PlushPose = poses[ordinal]
private fun Float.safeGaze(): Float = if (isFinite()) coerceIn(-1f, 1f) else 0f
private fun PlushDotState.defaultLabel(): String = when (this) {
    PlushDotState.Idle -> "待命"
    PlushDotState.Listening -> "正在倾听"
    PlushDotState.Thinking -> "正在思考"
    PlushDotState.Working -> "正在处理"
    PlushDotState.Success -> "已完成"
    PlushDotState.Error -> "需要帮助"
    PlushDotState.Sleep -> "休息中"
    PlushDotState.Curious -> "好奇"
}

private class FiberBatch(val path: Path, val color: Color, val stroke: Stroke)

/** All paths, brushes, fiber geometry, and strokes are immutable after construction. */
private class PlushArtwork(quality: PlushFurQuality, private val showBeret: Boolean, textureSize: Int) {
    private val body = Path().apply {
        for (i in 0..360) {
            val point = contour(i * TAU / 360f)
            if (i == 0) moveTo(point.x, point.y) else lineTo(point.x, point.y)
        }
        close()
    }
    private val bodyFill = Brush.radialGradient(
        0f to Color(0xFFC0CFFF), 0.38f to Color(0xFF839EEF),
        0.75f to Color(0xFF6684D4), 1f to Color(0xFF3C519C),
        center = Offset(-31f, -43f), radius = 164f,
    )
    private val bodyGlow = Brush.radialGradient(
        listOf(Color(0xFFFFFFFF).copy(alpha = 0.26f), Color.Transparent),
        center = Offset(-50f, -56f), radius = 70f,
    )
    private val underHat = Brush.radialGradient(
        listOf(Color(0xFF35497F).copy(alpha = 0.18f), Color.Transparent),
        center = Offset(-12f, -65f), radius = 69f,
    )
    private val fur = makeFur(if (quality == PlushFurQuality.High) 6400 else 2900)
    private val fringe = makeFringe(if (quality == PlushFurQuality.High) 1300 else 650)
    private val beret = Path().apply {
        moveTo(-72f, 7f)
        cubicTo(-77f, -11f, -48f, -30f, -9f, -30f)
        cubicTo(34f, -31f, 70f, -20f, 73f, -3f)
        cubicTo(78f, 17f, 44f, 29f, 4f, 29f)
        cubicTo(-35f, 30f, -66f, 25f, -72f, 7f)
        close()
    }
    private val hatFill = Brush.linearGradient(
        0f to Color(0xFF35384E), 0.30f to Color(0xFF25273C),
        0.72f to Color(0xFF181B2C), 1f to Color(0xFF0C0F1E),
        start = Offset(-20f, -32f), end = Offset(18f, 31f),
    )
    private val hatGlow = Brush.radialGradient(
        listOf(Color.White.copy(alpha = 0.14f), Color.Transparent),
        center = Offset(-25f, -7f), radius = 46f,
    )
    private val hatLip = Path().apply {
        moveTo(-62f, 16f)
        cubicTo(-22f, 31f, 44f, 23f, 64f, 11f)
    }
    private val hatLipStroke = Stroke(2.6f, cap = StrokeCap.Round)
    private val stemFill = Brush.linearGradient(
        listOf(Color(0xFF454B69), Color(0xFF121626)),
        start = Offset(3f, -40f), end = Offset(13f, -29f),
    )
    private val happyEye = Path().apply {
        moveTo(-6.5f, 2f)
        quadraticBezierTo(0f, -6f, 6.5f, 2f)
    }
    private val eyeStroke = Stroke(5f, cap = StrokeCap.Round)
    private val cueStroke = Stroke(2.4f, cap = StrokeCap.Round)
    private val check = Path().apply { moveTo(-7f, 0f); lineTo(-2f, 5f); lineTo(8f, -6f) }
    private val question = Path().apply {
        moveTo(-5f, -6f); cubicTo(-5f, -12f, 7f, -12f, 6f, -5f)
        cubicTo(5f, -1f, 0f, -2f, 0f, 3f)
    }
    private val sleepZ = Path().apply {
        moveTo(-5f, -6f); lineTo(5f, -6f); lineTo(-5f, 5f); lineTo(5f, 5f)
    }

    fun drawBody(scope: DrawScope) = with(scope) {
        // Outward hairs precede the opaque body; interior strands are clipped to its contour.
        fringe.forEach { drawPath(it.path, it.color, style = it.stroke) }
        drawPath(body, bodyFill)
        clipPath(body) {
            drawCircle(bodyGlow, radius = 91f, center = Offset(-38f, -41f))
            if (showBeret) drawOval(underHat, topLeft = Offset(-64f, -94f), size = Size(110f, 70f))
            fur.forEach { drawPath(it.path, it.color, style = it.stroke) }
        }
    }

    // Rasterize thousands of fixed fibers only once. The small grid, not the fur paths,
    // is updated per frame; every fiber then follows the same local deformation field.
    private val texture = ImageBitmap(textureSize, textureSize).also { image ->
        val edge = textureSize.toFloat()
        CanvasDrawScope().draw(Density(1f), LayoutDirection.Ltr, GraphicsCanvas(image), Size(edge, edge)) {
            translate(edge / 2f, edge / 2f) {
                scale(edge / 224f, edge / 224f, pivot = Offset.Zero) { drawBody(this) }
            }
        }
    }.asAndroidBitmap()
    private val mesh = FloatArray((MESH + 1) * (MESH + 1) * 2)
    private val texturePaint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG or android.graphics.Paint.FILTER_BITMAP_FLAG)

    fun contains(point: Offset): Boolean {
        val angle = atan2(point.y / 1.015f, point.x)
        return sqrt(point.x * point.x + point.y * point.y / (1.015f * 1.015f)) < radiusAt(angle)
    }

    fun drawDeformedBody(scope: DrawScope, softBody: PlushSoftBody) = with(scope) {
        var index = 0
        for (row in 0..MESH) for (column in 0..MESH) {
            val p = softBody.warp(Offset(-112f + column * 224f / MESH, -112f + row * 224f / MESH))
            mesh[index++] = p.x
            mesh[index++] = p.y
        }
        drawIntoCanvas { canvas ->
            canvas.nativeCanvas.drawBitmapMesh(texture, MESH, MESH, mesh, 0, null, 0, texturePaint)
        }
    }

    fun drawAttachedEye(scope: DrawScope, softBody: PlushSoftBody, center: Offset, openness: Float, happy: Float) = with(scope) {
        val anchor = softBody.warp(center)
        val axisX = softBody.warp(center + Offset(1f, 0f)) - anchor
        val axisY = softBody.warp(center + Offset(0f, 1f)) - anchor
        translate(anchor.x, anchor.y) {
            rotate(atan2(axisX.y, axisX.x) * 180f / kotlin.math.PI.toFloat(), pivot = Offset.Zero) {
                scale(axisX.getDistance().coerceIn(0.65f, 1.45f), axisY.getDistance().coerceIn(0.65f, 1.45f), pivot = Offset.Zero) {
                    val h = (32f * openness).coerceAtLeast(2.4f)
                    if (happy < 0.999f) drawRoundRect(Color(0xFF15192C),
                        topLeft = Offset(-8f, -h / 2f), size = Size(16f, h),
                        cornerRadius = CornerRadius(min(8f, h / 2f)), alpha = 1f - happy)
                    if (happy > 0.001f) drawPath(happyEye, Color(0xFF15192C), alpha = happy, style = eyeStroke)
                }
            }
        }
    }

    fun drawBeret(scope: DrawScope, anchor: Offset, secondaryTilt: Float, lift: Float) = with(scope) {
        translate(anchor.x, anchor.y + lift) {
            scale(0.75f, 0.75f, pivot = Offset.Zero) {
                rotate(-14f + secondaryTilt, pivot = Offset.Zero) {
                    // Stem sits behind the crown, as in the reference photograph.
                    rotate(-7f, pivot = Offset(8f, -29f)) {
                        drawOval(stemFill, topLeft = Offset(3f, -42f), size = Size(10f, 16f))
                    }
                    drawPath(beret, hatFill)
                    clipPath(beret) {
                        scale(1f, 0.42f, pivot = Offset(-25f, -7f)) {
                            drawCircle(hatGlow, radius = 50f, center = Offset(-25f, -7f))
                        }
                        drawPath(hatLip, Color(0xFF090D1C).copy(alpha = 0.35f), style = hatLipStroke)
                    }
                }
            }
        }
    }

    fun drawStatus(scope: DrawScope, state: PlushDotState, t: Float, moving: Boolean, anchor: Offset) = with(scope) {
        val badge = when (state) {
            PlushDotState.Thinking, PlushDotState.Working -> Color(0xFF78BBF5)
            PlushDotState.Error -> Color(0xFFFF9E8E)
            PlushDotState.Sleep -> Color(0xFFBDD2CA)
            else -> Color(0xFFA5F46A)
        }
        val ink = Color(0xFF1D3930)
        translate(anchor.x, anchor.y) {
            // drawCircle's default center belongs to the full canvas, even after
            // translate. Every badge primitive must use this local head anchor.
            drawCircle(Color(0xFFF5F9F3), 14.5f, center = Offset.Zero)
            drawCircle(badge, 13f, center = Offset.Zero)
            when (state) {
                PlushDotState.Listening -> for (i in -1..1) {
                    val h = if (moving) 8f + (1f + sin(t * 5f + i)) * 4f else 10f + (1 - kotlin.math.abs(i)) * 4f
                    drawLine(ink, Offset(i * 5f, -h / 2f), Offset(i * 5f, h / 2f), 2.4f, StrokeCap.Round)
                }
                PlushDotState.Thinking -> for (i in -1..1) {
                    val pulse = if (moving) (sin(t * 3.8f - i * 0.8f) + 1f) / 2f else 1f
                    drawCircle(ink.copy(alpha = 0.4f + pulse * 0.6f), 2.5f, Offset(i * 6f, -pulse * 1.8f))
                }
                PlushDotState.Working -> drawArc(ink,
                    startAngle = if (moving) (t * 120f) % 360f else -60f,
                    sweepAngle = 265f, useCenter = false,
                    topLeft = Offset(-8f, -8f), size = Size(16f, 16f), style = cueStroke)
                PlushDotState.Success -> drawPath(check, ink, style = cueStroke)
                PlushDotState.Error -> {
                    drawLine(ink, Offset(0f, -8f), Offset(0f, 1f), 2.5f, StrokeCap.Round)
                    drawCircle(ink, 1.5f, Offset(0f, 7f))
                }
                PlushDotState.Sleep -> translate(0f, if (moving) -sin(t * 1.5f) * 2f else 0f) {
                    drawPath(sleepZ, ink, style = cueStroke)
                }
                PlushDotState.Curious -> {
                    drawPath(question, ink, style = cueStroke)
                    drawCircle(ink, 1.4f, Offset(0f, 8f))
                }
                else -> drawCircle(ink, 2.5f, center = Offset.Zero)
            }
        }
    }
}

private const val MESH = 28
private const val TAU = 6.2831855f
private fun radiusAt(angle: Float): Float =
    82f + 2.3f * cos(3f * (angle - 0.26f)) + 0.8f * cos(5f * angle + 0.6f)
private fun contour(angle: Float): Offset {
    val radius = radiusAt(angle)
    return Offset(cos(angle) * radius, sin(angle) * radius * 1.015f)
}

private fun makeFur(count: Int): List<FiberBatch> {
    val random = Random(73129)
    val colors = listOf(
        Color(0xFF35497F).copy(alpha = 0.16f), Color(0xFF475C99).copy(alpha = 0.22f),
        Color(0xFF5367AD).copy(alpha = 0.17f), Color(0xFF7587C6).copy(alpha = 0.21f),
        Color(0xFFC0CFFF).copy(alpha = 0.26f), Color(0xFFDDE6FF).copy(alpha = 0.24f),
        Color(0xFFCAD7FF).copy(alpha = 0.20f), Color(0xFFEAF0FF).copy(alpha = 0.15f),
        Color(0xFFFFFFFF).copy(alpha = 0.11f), Color(0xFF9AB0EA).copy(alpha = 0.22f),
    )
    val paths = List(colors.size) { Path() }
    repeat(count) {
        val angle = random.nextFloat() * TAU
        val radius = sqrt(random.nextFloat()) * radiusAt(angle)
        val x = cos(angle) * radius
        val y = sin(angle) * radius * 1.015f
        val direction = atan2(y + 25f, x + 15f) + 0.35f + (random.nextFloat() - 0.5f) * 1.5f
        val length = 1.2f + random.nextFloat() * 3.5f
        val dx = cos(direction) * length
        val dy = sin(direction) * length
        val curl = (random.nextFloat() - 0.5f) * 1.5f
        paths[random.nextInt(paths.size)].apply {
            moveTo(x, y)
            quadraticBezierTo(x + dx * 0.5f - dy * curl * 0.25f,
                y + dy * 0.5f + dx * curl * 0.25f, x + dx, y + dy)
        }
    }
    return paths.mapIndexed { i, path ->
        FiberBatch(path, colors[i], Stroke(0.44f + (i % 3) * 0.10f, cap = StrokeCap.Round))
    }
}

private fun makeFringe(count: Int): List<FiberBatch> {
    val random = Random(24177)
    val paths = List(5) { Path() }
    repeat(count) {
        val angle = random.nextFloat() * TAU
        val point = contour(angle)
        val before = contour(angle - 0.004f)
        val after = contour(angle + 0.004f)
        val tangentX = after.x - before.x
        val tangentY = after.y - before.y
        val tangentLength = sqrt(tangentX * tangentX + tangentY * tangentY).coerceAtLeast(0.001f)
        val nx = tangentY / tangentLength
        val ny = -tangentX / tangentLength
        val hair = 1f + random.nextFloat() * 2.7f
        val bend = (random.nextFloat() - 0.5f) * 1.9f
        paths[random.nextInt(paths.size)].apply {
            moveTo(point.x - nx * 1.4f, point.y - ny * 1.4f)
            quadraticBezierTo(point.x + nx * hair * 0.5f - ny * bend,
                point.y + ny * hair * 0.5f + nx * bend,
                point.x + nx * hair, point.y + ny * hair)
        }
    }
    val colors = listOf(0xFF8C9FE0, 0xFFB4C6F5, 0xFFD1DDFF, 0xFF677CBD, 0xFFC0CFFF)
    return paths.mapIndexed { i, path ->
        FiberBatch(path, Color(colors[i]).copy(alpha = if (i == 4) 0.22f else 0.48f),
            Stroke(0.55f + i * 0.055f, cap = StrokeCap.Round))
    }
}


private fun Offset.limited(limit: Float): Offset {
    val length = getDistance()
    return if (length > limit) this * (limit / length) else this
}

/** Inverse of the same body transform used when drawing, in 320-unit coordinates. */
private data class PlushFrame(
    var centerX: Float = 0f, var centerY: Float = 0f, var unit: Float = 1f,
    var lift: Float = 0f, var angle: Float = 0f, var wide: Float = 1f, var tall: Float = 1f,
) {
    fun update(x: Float, y: Float, u: Float, l: Float, a: Float, w: Float, h: Float) {
        centerX = x; centerY = y; unit = u; lift = l; angle = a; wide = w; tall = h
    }
    fun local(point: Offset): Offset {
        val p = (point - Offset(centerX, centerY)) / unit.coerceAtLeast(0.001f) - Offset(0f, 24f + lift)
        val radians = -angle * kotlin.math.PI.toFloat() / 180f
        return Offset((p.x * cos(radians) - p.y * sin(radians)) / wide,
            (p.x * sin(radians) + p.y * cos(radians)) / tall)
    }
}

/** A pinned Gaussian displacement field with perpendicular volume compensation. */
private class PlushSoftBody {
    var grabbing = false
        private set
    var grab = Offset.Zero
        private set
    var pull = Offset.Zero
        private set
    var hatPull = Offset.Zero
        private set
    private var velocity = Offset.Zero
    private var dragOrigin = Offset.Zero
    private var targetGrab = Offset.Zero
    private var grabFrom = Offset.Zero
    private var grabMigration = 0.09f
    private var hatVelocity = Offset.Zero

    fun begin(at: Offset) {
        // Preserve the exact field at takeover, then move its center to the new
        // touch point over 90ms. Switching sides during recovery must not pop.
        targetGrab = at
        if (pull.getDistance() < 0.5f) {
            grab = at
            grabMigration = 0.09f
        } else {
            grabMigration = 0f
        }
        grabFrom = grab
        dragOrigin = pull
        grabbing = true
        velocity = Offset.Zero
    }
    fun move(displacement: Offset, direct: Boolean) {
        pull = (dragOrigin + displacement).limited(90f)
        if (direct) hatPull = pull
    }
    fun release(direct: Boolean) {
        grabbing = false
        if (direct) reset()
    }
    fun reset() {
        grabbing = false
        pull = Offset.Zero
        hatPull = Offset.Zero
        velocity = Offset.Zero
        dragOrigin = Offset.Zero
        targetGrab = grab
        grabFrom = grab
        grabMigration = 0.09f
        hatVelocity = Offset.Zero
    }
    fun restPoint(displayPoint: Offset): Offset {
        var point = displayPoint
        repeat(12) { point += displayPoint - warp(point) }
        return point
    }
    fun step(dt: Float) {
        // Bounded substeps avoid unstable integration on low-refresh or missed frames.
        var remaining = dt.coerceIn(0f, 0.05f)
        while (remaining > 0f) {
            val h = min(remaining, 1f / 120f)
            if (grabbing && grabMigration < 0.09f) {
                grabMigration = min(0.09f, grabMigration + h)
                val u = grabMigration / 0.09f
                grab = grabFrom + (targetGrab - grabFrom) * (u * u * (3f - 2f * u))
            }
            if (!grabbing) {
                velocity += (pull * -196f - velocity * 15.4f) * h
                pull += velocity * h
            }
            hatVelocity += ((pull - hatPull) * 120f - hatVelocity * 14f) * h
            hatPull += hatVelocity * h
            remaining -= h
        }
        if (!grabbing && pull.getDistance() < 0.025f && velocity.getDistance() < 0.05f && hatPull.getDistance() < 0.025f) reset()
    }
    fun warp(point: Offset, displacement: Offset = pull): Offset {
        val length = displacement.getDistance()
        if (length < 0.001f) return point
        val delta = point - grab
        val influence = exp(-delta.getDistanceSquared() / (2f * 80f * 80f))
        val direction = displacement / length
        val perpendicular = Offset(-direction.y, direction.x)
        val cross = delta.x * perpendicular.x + delta.y * perpendicular.y
        val compression = perpendicular * (-cross * min(length / 90f, 1f) * 0.18f * influence)
        return point + displacement * (0.18f + 0.82f * influence) + compression
    }
}
