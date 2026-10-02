package work.eddie.sessions

import org.junit.Assert.*
import org.junit.Test

class TaskLedgerTest {
 @Test fun unknownAndEndedNeverClaimCompletion(){
  for(status in listOf("", "future_state", "unknown", "ended"))assertEquals("attention",ledgerStatus(status).first)
  assertEquals("取消待确认",ledgerStatus("cancel_requested").second)
  assertEquals("已停止 · 未完成验收",ledgerStatus("interrupted").second)
  assertEquals("执行结束 · 待验收",ledgerStatus("completed").second)
 }
}
