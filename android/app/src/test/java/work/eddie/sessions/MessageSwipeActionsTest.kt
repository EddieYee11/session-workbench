package work.eddie.sessions

import org.junit.Assert.*
import org.junit.Test

class MessageSwipeActionsTest {
    @Test fun releaseBelowThresholdAndReverseAfterArmingDoNotCommit() {
        assertNull(messageSwipeIntent(55.9f, 56f))
        assertNull(messageSwipeIntent(-55.9f, 56f))
        assertEquals(MessageSwipeIntent.Reply, messageSwipeIntent(56f, 56f))
        assertEquals(MessageSwipeIntent.Forward, messageSwipeIntent(-56f, 56f))
        val cue = MessageSwipeFeedback()
        assertTrue(cue.cross(70f, 56f))
        assertNull(messageSwipeIntent(30f, 56f))
        assertFalse(cue.cross(70f, 56f))
        assertFalse(cue.cross(-70f, 56f))
    }
    @Test fun verticalScrollingAndTextSelectionWinBeforeHorizontalClaim() {
        assertEquals(MessageSwipeAxis.Vertical, messageSwipeAxis(25f, 45f, 60, 8f, 500))
        assertEquals(MessageSwipeAxis.Horizontal, messageSwipeAxis(45f, 15f, 60, 8f, 500))
        assertEquals(MessageSwipeAxis.Pending, messageSwipeAxis(9f, 8f, 60, 8f, 500))
        assertEquals(MessageSwipeAxis.TextSelection, messageSwipeAxis(45f, 0f, 501, 8f, 500))
        assertNull(messageSwipeIntent(Float.NaN, 56f))
        assertNull(messageSwipeIntent(60f, 0f))
    }
}
