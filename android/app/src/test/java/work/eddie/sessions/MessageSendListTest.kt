package work.eddie.sessions

import org.junit.Assert.assertEquals
import org.junit.Test

class MessageSendListTest {
    @Test fun rowAndFollowingGapShareOneExpansionProgress() {
        assertEquals(0, messageSendExpandedHeight(180, 26, 0f))
        assertEquals(103, messageSendExpandedHeight(180, 26, .5f))
        assertEquals(206, messageSendExpandedHeight(180, 26, 1f))
        assertEquals(0, messageSendExpandedHeight(180, 26, -1f))
        assertEquals(206, messageSendExpandedHeight(180, 26, 2f))
    }

    @Test fun onlyActualViewportOverflowMovesThePreviousMessages() {
        assertEquals(0f, messageSendViewportOverflow(100, 50, 300, 12), 0f)
        assertEquals(0f, messageSendViewportOverflow(288, 0, 300, 12), 0f)
        assertEquals(75f, messageSendViewportOverflow(288, 75, 300, 12), 0f)
        assertEquals(150f, messageSendViewportOverflow(288, 150, 300, 12), 0f)
    }
}
