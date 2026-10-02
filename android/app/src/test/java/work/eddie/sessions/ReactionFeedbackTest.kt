package work.eddie.sessions

import org.junit.Assert.*
import org.junit.Test

class ReactionFeedbackTest {
    private val old = ReactionFeedback("user-1", "reaction-1", "👍")
    private val fresh = ReactionFeedback("user-2", "reaction-2", "❤️")

    @Test fun historyAndReconnectNeverVibrate() {
        val tracker = ReactionFeedbackTracker()
        tracker.baseline(listOf(old))
        assertNull(tracker.live(listOf(old)))
        tracker.baseline(listOf(old, fresh))
        assertNull(tracker.live(listOf(fresh)))
    }

    @Test fun liveReactionFiresOnceDespiteDuplicateEventsAndRefresh() {
        val tracker = ReactionFeedbackTracker()
        tracker.baseline(listOf(old))
        assertEquals(fresh, tracker.live(listOf(fresh)))
        assertNull(tracker.live(listOf(fresh)))
        tracker.baseline(listOf(old, fresh))
        assertNull(tracker.live(listOf(fresh)))
    }

    @Test fun eventsBeforeInitialSnapshotStayQuiet() {
        val tracker = ReactionFeedbackTracker()
        assertNull(tracker.live(listOf(old)))
        tracker.baseline(listOf(old))
        assertEquals(fresh, tracker.live(listOf(fresh)))
    }
}
