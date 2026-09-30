package work.eddie.sessions

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceSheetGestureTest {
    @Test fun pausingAfterAFastShortDragDoesNotAccidentallyExpand() {
        val velocity = voiceSheetReleaseVelocity(-1400f, 500)
        assertFalse(shouldExpandVoiceSheet(.25f, velocity, 900f))
    }

    @Test fun holdingAfterDownwardReversalUsesPositionRatherThanOldVelocity() {
        val velocity = voiceSheetReleaseVelocity(1400f, 500)
        assertTrue(shouldExpandVoiceSheet(.7f, velocity, 900f))
        assertFalse(shouldExpandVoiceSheet(.7f, voiceSheetReleaseVelocity(1400f, 20), 900f))
    }

    @Test fun shortSlowDragReturnsToTheSmallWindow() {
        assertFalse(shouldExpandVoiceSheet(.25f, -200f, 900f))
    }

    @Test fun deliberateUpwardFlingExpandsWithoutCrossingThePositionThreshold() {
        assertTrue(shouldExpandVoiceSheet(.2f, -1100f, 900f))
    }

    @Test fun downwardReversalCancelsEvenAfterMostOfTheExpansion() {
        assertFalse(shouldExpandVoiceSheet(.8f, 1100f, 900f))
    }

    @Test fun slowReleaseSettlesToTheNearestIntent() {
        assertFalse(shouldExpandVoiceSheet(.44f, 0f, 900f))
        assertTrue(shouldExpandVoiceSheet(.45f, 0f, 900f))
    }
}
