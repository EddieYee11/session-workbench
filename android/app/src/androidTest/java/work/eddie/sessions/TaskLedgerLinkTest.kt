package work.eddie.sessions

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONObject

@RunWith(AndroidJUnit4::class)
class TaskLedgerLinkTest {
 @Test fun taskIdentityDoesNotMergeSameParent(){
  val A=JSONObject().put("id","A").put("parent_message_id","source").put("status","unknown")
  val B=JSONObject().put("id","B").put("message_id","source").put("status","interrupted")
  val tasks=buildLedgerTasks(listOf(A,B),emptyList())
  assertEquals(setOf("A","B"),tasks.map{it.id}.toSet())
  assertTrue(tasks.all{it.messageId=="source"})
  assertEquals("source",ledgerParent(JSONObject().put("origin_message_id","source")))
 }
}
