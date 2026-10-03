package work.eddie.sessions
import org.junit.Test
import org.junit.Assert.*
class TaskPresentationTest {
 @Test fun incompleteCallsNeverClaimCompletion(){assertTrue(stepText("tool.started","read",1).contains("尚未确认"));assertTrue(stepText("tool.failed","read",1).contains("失败"))}
 @Test fun unknownCallsStayNeutral(){assertEquals("other",stepCategory("future_tool"));assertEquals("执行了 2 项操作",stepText("tool.completed","other",2))}
 @Test fun searchCallCountsAreNotInventedSourceCounts(){assertEquals("完成 3 次搜索",stepText("tool.completed","search",3))}
}
