package work.eddie.sessions

import android.animation.ValueAnimator
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.foundation.layout.BoxWithConstraints
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

/**
 * The supplied crab is Hermes' companion. The caller supplies actual conversation
 * state: idle / listening / thinking / working / responding / success / error / offline.
 * A response is responding, not success; only a confirmed completion may celebrate.
 * Haptics belong to the caller's business event, so a header and hero cannot buzz twice.
 */
@Composable
fun HermesCompanion(
    state: String,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
    animationActive: Boolean = true,
) {
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

    val normalizedState = CrabAvatarState.normalize(state)
    var feedbackFinished by remember(normalizedState) { mutableStateOf(false) }
    LaunchedEffect(normalizedState) {
        if (normalizedState == CrabAvatarState.SUCCESS) {
            delay(1_600L)
            feedbackFinished = true
        }
    }
    val displayState = if (feedbackFinished) CrabAvatarState.IDLE else normalizedState

    BoxWithConstraints(
        modifier = modifier.size(200.dp).onGloballyPositioned { coordinates ->
            val bounds = coordinates.boundsInWindow()
            visible = bounds.width > 0f && bounds.height > 0f &&
                bounds.bottom > 0f && bounds.right > 0f &&
                bounds.top < view.rootView.height && bounds.left < view.rootView.width
        }.semantics {
            contentDescription = "Pi 螃蟹伙伴，${CrabAvatarState.defaultCopy(displayState)}"
        },
        contentAlignment = Alignment.Center,
    ) {
        CrabAvatar(
            state = displayState,
            modifier = Modifier.fillMaxSize(),
            reducedMotion = reducedMotion,
            isAnimationActive = animationActive && resumed && visible,
            compact = compact || maxWidth <= 88.dp || maxHeight <= 88.dp,
        )
    }
}
