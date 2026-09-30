package work.eddie.sessions

/** A finger held still before release must not reuse its earlier fling speed. */
internal fun voiceSheetReleaseVelocity(measuredVelocity: Float, idleMillis: Long): Float =
    if (idleMillis > 100L) 0f else measuredVelocity

/** A deliberate fling wins over position, including a downward reversal. */
internal fun shouldExpandVoiceSheet(progress: Float, velocityY: Float, flingThreshold: Float): Boolean =
    when {
        velocityY <= -flingThreshold -> true
        velocityY >= flingThreshold -> false
        else -> progress >= .45f
    }
