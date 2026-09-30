package work.eddie.sessions

import android.animation.ValueAnimator
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.delay

/** Pi owns the fluid face; Codex owns the native, blue plush companion. */
@Composable
fun CompanionAvatar(
    agent: String,
    state: String,
    modifier: Modifier = Modifier,
    interactive: Boolean = true,
    compact: Boolean = false,
    showGroundShadow: Boolean = true,
    nativeAnimationActive: Boolean = true,
) {
    if (!agent.equals("codex", ignoreCase = true)) {
        Box(modifier) {
            if (showGroundShadow) CompanionGroundShadow(Modifier.fillMaxSize(), compact = compact)
            BotAvatar(
                state = state,
                modifier = Modifier.fillMaxSize().semantics { contentDescription = "Pi 圆脸伙伴" },
                interactive = interactive,
            )
        }
        return
    }

    val context = LocalContext.current
    val view = LocalView.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var resumed by remember(lifecycle) {
        mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
    }
    var reducedMotion by remember { mutableStateOf(!ValueAnimator.areAnimatorsEnabled()) }
    var visible by remember { mutableStateOf(true) }
    DisposableEffect(context, lifecycle) {
        val motionObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                reducedMotion = !ValueAnimator.areAnimatorsEnabled()
            }
        }
        val lifecycleObserver = LifecycleEventObserver { _, _ ->
            resumed = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            reducedMotion = !ValueAnimator.areAnimatorsEnabled()
        }
        context.contentResolver.registerContentObserver(
            Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, motionObserver,
        )
        lifecycle.addObserver(lifecycleObserver)
        onDispose {
            context.contentResolver.unregisterContentObserver(motionObserver)
            lifecycle.removeObserver(lifecycleObserver)
        }
    }

    // Consume one-shot input once, like Pi's controller. Recomposition or a resume
    // never manufactures a new completion; a later business state cancels the timer.
    val normalizedState = state.lowercase()
    var feedbackFinished by remember(normalizedState) { mutableStateOf(false) }
    LaunchedEffect(normalizedState) {
        val duration = when (normalizedState) {
            "happy" -> 2_200L
            "greeting" -> 1_600L
            else -> return@LaunchedEffect
        }
        delay(duration)
        feedbackFinished = true
    }
    val displayState = if (feedbackFinished) "idle" else normalizedState

    BoxWithConstraints(
        modifier = modifier.size(240.dp).onGloballyPositioned { coordinates ->
            val bounds = coordinates.boundsInWindow()
            visible = bounds.width > 0f && bounds.height > 0f &&
                bounds.bottom > 0f && bounds.right > 0f &&
                bounds.top < view.rootView.height && bounds.left < view.rootView.width
        },
        contentAlignment = Alignment.Center,
    ) {
        val small = compact || maxWidth <= 88.dp || maxHeight <= 88.dp
        if (showGroundShadow) CompanionGroundShadow(Modifier.fillMaxSize(), compact = small)
        PlushDotMascot(
            state = plushVisualState(displayState),
            modifier = Modifier.fillMaxSize().graphicsLayer {
                // At 64dp the body otherwise occupies only 33dp. Leave the native
                // square intact for dragging, and enlarge only decorative instances.
                scaleX = if (small && !interactive) 1.30f else 1f
                scaleY = scaleX
            },
            reducedMotion = reducedMotion,
            isAnimationActive = resumed && visible && nativeAnimationActive,
            onTap = if (interactive) ({ /* The component supplies tactile squeeze feedback. */ }) else null,
            showStatusMark = !small,
            furQuality = if (small) PlushFurQuality.Standard else PlushFurQuality.High,
            description = if (interactive) "Codex 蓝色毛绒伙伴，轻点或拖动互动" else "Codex 蓝色毛绒伙伴",
            stateLabel = plushStateLabel(displayState),
            dragEnabled = interactive,
            textureResolution = if (small) 336 else 672,
        )
    }
}

/** Only host-provided success can produce happy eyes; unknown/progress-less states stay idle. */
internal fun plushVisualState(state: String): PlushDotState = when (state) {
    "listening" -> PlushDotState.Listening
    "thinking" -> PlushDotState.Thinking
    "speaking", "working" -> PlushDotState.Working
    "happy" -> PlushDotState.Success
    "error" -> PlushDotState.Error
    "curious", "greeting" -> PlushDotState.Curious
    "sleep" -> PlushDotState.Sleep
    else -> PlushDotState.Idle
}

private fun plushStateLabel(state: String): String = when (state) {
    "listening" -> "正在倾听"
    "thinking" -> "正在思考"
    "speaking" -> "正在回应"
    "working" -> "正在处理"
    "happy" -> "已完成"
    "error" -> "出现问题"
    "curious" -> "等待你的回应"
    "greeting" -> "向你打招呼"
    "sleep" -> "休息中"
    else -> "待命"
}
