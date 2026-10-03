package work.eddie.sessions

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class ConversationOutboxPersistenceTest {
 @Test fun restartRetainsMultipleBodiesAndOnlyAnExactReceiptSettlesOne(){
  val store=Store(InstrumentationRegistry.getInstrumentation().targetContext)
  val key="test-outbox-${UUID.randomUUID()}"
  try{
   val pending=listOf(ConversationOutboxEntry("a","继续",state="sending",createdAt=1.0),
    ConversationOutboxEntry("b","继续",state="unknown",createdAt=2.0),
    ConversationOutboxEntry("c","独立新任务",state="queued_local",createdAt=3.0))
   store.saveSecureText(key,serializeConversationOutbox(pending),durable=true)
   val restored=readConversationOutbox(store.secureText(key))
   assertEquals(listOf("a","b","c"),restored.map{it.id})
   assertEquals(listOf("unknown","unknown","queued_local"),restored.map{it.state})
   val sameBody=JSONObject().put("id","unbound").put("role","user").put("text","继续")
   assertEquals(restored,reconcileConversationOutbox(restored,listOf(sameBody)))
   val exact=JSONObject().put("id","native-b").put("role","user").put("request_id","b").put("text","继续")
   val reconciled=reconcileConversationOutbox(restored,listOf(exact))
   assertEquals("unknown",reconciled[0].state)
   assertEquals("accepted",reconciled[1].state)
   assertEquals("native-b",reconciled[1].serverId)
   assertEquals("queued_local",reconciled[2].state)
   store.saveSecureText(key,serializeConversationOutbox(reconciled),durable=true)
   assertEquals(listOf("unknown","accepted","queued_local"),readConversationOutbox(store.secureText(key)).map{it.state})
  }finally{store.saveSecureText(key,"",durable=true)}
 }
 @Test fun legacyPendingMessageMigratesWithoutSending(){
  val legacy=JSONObject().put("request_id","legacy").put("text","旧消息").toString()
  val migrated=readConversationOutbox("",legacy)
  assertEquals(1,migrated.size)
  assertEquals("legacy",migrated.single().id)
  assertEquals("unknown",migrated.single().state)
 }
 @Test fun persistedEnqueueClearsTheDraftAndCancelsAnOlderDelayedWrite(){
  val store=Store(InstrumentationRegistry.getInstrumentation().targetContext)
  val prefix="test-atomic-${UUID.randomUUID()}"
  val draft="$prefix-draft";val outbox="$prefix-outbox"
  try{
   store.saveSecureTextSoon(draft,"旧草稿")
   val body=serializeConversationOutbox(listOf(ConversationOutboxEntry("queued","已发送的内容",state="queued_local")))
   store.saveSecureTexts(mapOf(draft to "",outbox to body),durable=true)
   store.flushPending()
   assertEquals("",store.secureText(draft))
   assertEquals("queued",readConversationOutbox(store.secureText(outbox)).single().id)
  }finally{store.saveSecureTexts(mapOf(draft to "",outbox to ""),durable=true)}
 }
}
