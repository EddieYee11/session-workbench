package work.eddie.sessions

import org.junit.Assert.*
import org.junit.Test

class ConversationOutboxTest {
 @Test fun processRestartNeverAutomaticallyReplaysUncertainRequests(){
  for(state in listOf("prepared","sending","unknown","future"))assertEquals("unknown",restoredOutboxState(state))
  assertEquals("accepted",restoredOutboxState("accepted"))
  assertEquals("abandoned",restoredOutboxState("abandoned"))
  assertEquals("queued_local",restoredOutboxState("queued_local"))
  assertTrue(canRetryOutbox("unknown"))
  for(state in listOf("prepared","sending","accepted","abandoned","queued_local"))assertFalse(canRetryOutbox(state))
 }
 @Test fun onlyAReferencedUncertainRequestBlocksASupplement(){
  val unknown=ConversationOutboxEntry("unknown-a","修改颜色",state="unknown")
  val accepted=ConversationOutboxEntry("accepted-b","查询日历",state="accepted",serverId="native-b")
  val entries=listOf(unknown,accepted)
  assertFalse(outboxDependencyBlocked("",entries))
  assertFalse(outboxDependencyBlocked("native-b",entries))
  assertFalse(outboxDependencyBlocked("another-task",entries))
  assertTrue(outboxDependencyBlocked("unknown-a",entries))
 }
 @Test fun requestReceiptDoesNotConfuseWorkerStateWithDelivery(){
  for(status in listOf("accepted","delegated","execution_finished","unknown","future_worker_state"))
   assertTrue(conversationReceiptConfirmed(status,"server-a","request-a","request-a"))
  assertFalse(conversationReceiptConfirmed("accepted","server-a","request-other","request-a"))
  assertFalse(conversationReceiptConfirmed("accepted","","request-a","request-a"))
  assertFalse(conversationReceiptConfirmed("accepted","null","request-a","request-a"))
  assertFalse(conversationReceiptConfirmed("","server-a","request-a","request-a"))
 }
}
