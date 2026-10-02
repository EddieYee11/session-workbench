package work.eddie.sessions

import org.junit.Assert.assertEquals
import org.junit.Test

class CrabAvatarStateTest {
    @Test fun cancellationAndGreetingDoNotInventTaskCompletion() {
        assertEquals(CrabAvatarState.IDLE, CrabAvatarState.normalize("cancelled"))
        assertEquals(CrabAvatarState.IDLE, CrabAvatarState.normalize("greeting"))
        assertEquals(CrabAvatarState.ERROR, CrabAvatarState.normalize("failed"))
    }

    @Test fun responseAndCompletionAreDifferentVisualStates() {
        assertEquals(CrabAvatarState.SPEAKING, CrabAvatarState.normalize(" responding "))
        // A generic completed event means the reply ended; it is not a ledger receipt.
        assertEquals(CrabAvatarState.IDLE, CrabAvatarState.normalize("completed"))
        assertEquals(CrabAvatarState.SUCCESS, CrabAvatarState.normalize("task_completed"))
        assertEquals(CrabAvatarState.IDLE, CrabAvatarState.normalize("unknown-event"))
    }
}
