package work.eddie.sessions

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** 内联任务卡按状态决定展开与折叠；纯映射逻辑，不依赖 Android 的 JSON 实现。 */
class MessageTaskCardTest {
    private fun task(id: String, status: String, raw: String = status, statusText: String = "") = LedgerTask(
        id = id, title = "任务 $id", agent = "CODEX", status = status,
        statusText = statusText.ifBlank { status }, updatedAt = 0.0, messageId = null, sessionId = "",
        events = emptyList(), rawStatus = raw,
    )

    @Test fun liveCardsCapAtThreeAndReportTheRest() {
        val plan = planInlineTasks((1..5).map { task("job-$it", "active", "running") })
        assertEquals(3, plan.cards.size)
        assertEquals(2, plan.hidden)
        assertEquals("active", plan.hiddenFilter)
        assertTrue(plan.ended.isEmpty())
    }

    @Test fun droppedDecisionTasksSendTheUserToTheDecisionFilter() {
        val plan = planInlineTasks(listOf(
            task("a", "active", "running"), task("b", "active", "running"), task("c", "active", "running"),
            task("d", "attention", "unknown"), task("e", "active", "running"),
        ))
        assertEquals(3, plan.cards.size)
        assertEquals(2, plan.hidden)
        assertEquals("decision", plan.hiddenFilter)
    }

    @Test fun endedTasksCollapseInsteadOfConsumingTheCap() {
        val plan = planInlineTasks(listOf(
            task("a", "active", "running"),
            task("b", "closed", "execution_finished", "验收通过"),
            task("c", "closed", "cancelled"),
            task("d", "closed", "execution_finished", "验收通过"),
        ))
        assertEquals(1, plan.cards.size)
        assertEquals(0, plan.hidden)
        assertEquals(3, plan.ended.size)
    }

    @Test fun pendingConfirmationStaysVisibleUntilTheUserChecksIt() {
        val plan = planInlineTasks(listOf(task("a", "closed", "execution_finished", "执行结束 · 待验收")))
        assertEquals(1, plan.cards.size)
        assertEquals("verify", ledgerGroup(plan.cards.single()))
        assertEquals(0, plan.hidden)
    }

    @Test fun emptyInputProducesNoCards() {
        val plan = planInlineTasks(emptyList())
        assertTrue(plan.cards.isEmpty())
        assertTrue(plan.ended.isEmpty())
        assertEquals(0, plan.hidden)
    }
}
