package work.eddie.sessions

import android.os.Build
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalView
import java.util.WeakHashMap

/** Semantic feedback for completed user actions, never for recomposition or loading ticks. */
enum class HapticCue { Selection, Commit, RecordingStart, RecordingStop, Expand, Reject }

/** Uses the platform's device-tuned effects and respects both view and system haptic settings. */
@Composable
fun rememberComHaptics(): (HapticCue) -> Unit {
    val view = LocalView.current
    return remember(view) { { cue -> ComHaptics.perform(view, cue) } }
}

private object ComHaptics {
    // Shared per host view so a parent and child handling one action cannot buzz twice.
    // Weak keys do not retain an Activity after its window has gone away.
    private class History {
        val cueTimes = LongArray(HapticCue.entries.size) { Long.MIN_VALUE }
        var lastAt = Long.MIN_VALUE
    }
    private val histories = WeakHashMap<View, History>()

    fun perform(view: View, cue: HapticCue) {
        if (!view.isAttachedToWindow || !view.isShown || !view.isHapticFeedbackEnabled) return
        val now = SystemClock.uptimeMillis()
        val history = histories.getOrPut(view) { History() }
        val sameAt = history.cueTimes[cue.ordinal]
        if (sameAt != Long.MIN_VALUE && now - sameAt < 100L) return
        // Recording edges describe real state changes and must not suppress each other,
        // even when the user immediately stops or cancels after recording starts.
        val recordingEdge = cue == HapticCue.RecordingStart || cue == HapticCue.RecordingStop
        if (!recordingEdge && history.lastAt != Long.MIN_VALUE && now - history.lastAt < 60L) return
        if (view.performHapticFeedback(cue.platformConstant())) {
            history.cueTimes[cue.ordinal] = now
            history.lastAt = now
        }
    }

    private fun HapticCue.platformConstant(): Int = when (this) {
        HapticCue.Selection -> if (Build.VERSION.SDK_INT >= 34) {
            HapticFeedbackConstants.SEGMENT_TICK
        } else HapticFeedbackConstants.CLOCK_TICK
        HapticCue.Commit -> if (Build.VERSION.SDK_INT >= 30) {
            HapticFeedbackConstants.CONFIRM
        } else HapticFeedbackConstants.VIRTUAL_KEY
        HapticCue.RecordingStart -> if (Build.VERSION.SDK_INT >= 30) {
            HapticFeedbackConstants.GESTURE_START
        } else HapticFeedbackConstants.CONTEXT_CLICK
        HapticCue.RecordingStop -> if (Build.VERSION.SDK_INT >= 30) {
            HapticFeedbackConstants.GESTURE_END
        } else HapticFeedbackConstants.VIRTUAL_KEY_RELEASE
        HapticCue.Expand -> when {
            Build.VERSION.SDK_INT >= 34 -> HapticFeedbackConstants.GESTURE_THRESHOLD_ACTIVATE
            Build.VERSION.SDK_INT >= 30 -> HapticFeedbackConstants.GESTURE_END
            else -> HapticFeedbackConstants.CONTEXT_CLICK
        }
        HapticCue.Reject -> if (Build.VERSION.SDK_INT >= 30) {
            HapticFeedbackConstants.REJECT
        } else HapticFeedbackConstants.LONG_PRESS
    }
}
