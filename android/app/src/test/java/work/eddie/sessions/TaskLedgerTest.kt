package work.eddie.sessions

import org.junit.Assert.*
import org.junit.Test

class TaskLedgerTest {
 private fun task(raw:String,verification:String=""):LedgerTask{
  val state=ledgerStatus(raw,verification)
  return LedgerTask("example","任务","CODEX",state.first,state.second,0.0,null,"",emptyList(),rawStatus=raw)
 }
 @Test fun filtersKeepDecisionsExecutionReviewAndAcceptanceDistinct(){
  assertEquals("decision",ledgerGroup(task("waiting")))
  assertEquals("decision",ledgerGroup(task("approval_required")))
  assertEquals("decision",ledgerGroup(task("unknown")))
  assertEquals("active",ledgerGroup(task("running")))
  assertEquals("verify",ledgerGroup(task("execution_finished")))
  assertEquals("done",ledgerGroup(task("execution_finished","passed")))
  assertEquals("ended",ledgerGroup(task("rejected")))
  assertEquals("ended",ledgerGroup(task("cancelled")))
 }
 @Test fun visibleGroupsAreFourAndUnknownNeedsHuman(){
  assertEquals("在办",ledgerVisibleGroup(task("running")))
  assertEquals("等我",ledgerVisibleGroup(task("unknown")))
  assertEquals("待确认",ledgerVisibleGroup(task("completed")))
  assertEquals("已结束",ledgerVisibleGroup(task("rejected")))
  assertEquals("需要你核实",ledgerStatus("unknown").second)
  assertEquals("closed",ledgerFilterGroup(task("execution_finished","passed")))
  assertEquals("closed",ledgerFilterGroup(task("cancelled")))
  assertEquals("decision",ledgerFilterGroup(task("unknown")))
 }
 @Test fun unknownAndEndedNeverClaimCompletion(){
  for(status in listOf("", "future_state", "unknown", "ended"))assertEquals("attention",ledgerStatus(status).first)
  assertEquals("正在停止",ledgerStatus("cancel_requested").second)
  assertEquals("已停止 · 未完成验收",ledgerStatus("interrupted").second)
  assertEquals("执行结束 · 待验收",ledgerStatus("completed").second)
  assertEquals("验收通过",ledgerStatus("execution_finished","passed").second)
  assertEquals("已暂停 · 等待继续",ledgerStatus("paused").second)
 }
}
