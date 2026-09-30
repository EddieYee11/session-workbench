package work.eddie.sessions

import org.junit.Assert.assertEquals
import org.junit.Test

class CompanionStateTest {
    @Test fun cachedCompletionDoesNotCelebrate() {
        assertEquals("idle", companionVisualState("completed", true))
        assertEquals("happy", companionVisualState("completed", true, previousStatus = "running"))
        assertEquals("idle", companionVisualState("completed", true, previousStatus = "completed"))
    }
    @Test fun offlineDoesNotPretendCachedWorkIsLive() {
        assertEquals("idle", companionVisualState("running", false))
        assertEquals("idle", companionVisualState("completed", false, previousStatus = "running"))
    }
    @Test fun failureAndApprovalTakePrecedenceOverNormalWork() {
        assertEquals("error", companionVisualState("failed", true, hasApproval = true))
        assertEquals("curious", companionVisualState("running", true, hasApproval = true))
        assertEquals("thinking", companionVisualState("running", true))
        assertEquals("curious", companionVisualState("waiting", true))
    }
}
