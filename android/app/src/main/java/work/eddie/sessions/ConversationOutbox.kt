package work.eddie.sessions

import org.json.JSONArray
import org.json.JSONObject

/** A request owns its immutable body. Uncertain sends never block unrelated messages. */
data class ConversationOutboxEntry(
 val id:String,val text:String,val reference:JSONObject?=null,val state:String="prepared",
 val serverId:String="",val createdAt:Double=System.currentTimeMillis()/1000.0,
)

fun restoredOutboxState(state:String):String = when(state){
 "prepared","sending"->"unknown" // The process may have died after the server received it.
 "accepted","unknown","abandoned","queued_local"->state
 else->"unknown"
}
fun canRetryOutbox(state:String)=state=="unknown"
fun conversationReceiptConfirmed(status:String,messageId:String,requestId:String,expectedRequestId:String):Boolean =
 status.isNotBlank()&&status!="null"&&messageId.isNotBlank()&&messageId!="null"&&requestId==expectedRequestId&&expectedRequestId.isNotBlank()
fun outboxDependencyBlocked(referenceId:String,entries:List<ConversationOutboxEntry>):Boolean =
 referenceId.isNotBlank()&&entries.any{(it.id==referenceId||it.serverId==referenceId)&&it.state in setOf("prepared","sending","unknown","abandoned","queued_local")}

fun readConversationOutbox(value:String,legacy:String=""):List<ConversationOutboxEntry>{
 val rows=runCatching{JSONObject(value).array("items")}.getOrDefault(emptyList()).ifEmpty{
  runCatching{JSONObject(legacy)}.getOrNull()?.takeIf{it.optString("request_id").isNotBlank()}?.let{listOf(it)}?:emptyList()
 }
 return rows.mapNotNull{row->
  val id=row.optString("request_id");val text=row.optString("text")
  if(id.isBlank()||text.isBlank())null else ConversationOutboxEntry(id,text,row.optJSONObject("reference"),
   restoredOutboxState(row.optString("state","unknown")),row.optString("message_id"),row.optDouble("created_at",0.0))
 }.distinctBy{it.id}
}
fun serializeConversationOutbox(entries:List<ConversationOutboxEntry>):String=JSONObject().put("items",JSONArray(entries.map{entry->
 JSONObject().put("request_id",entry.id).put("text",entry.text).put("reference",entry.reference?:JSONObject.NULL)
  .put("state",entry.state).put("message_id",entry.serverId).put("created_at",entry.createdAt)
})).toString()
fun ConversationOutboxEntry.body()=JSONObject().put("request_id",id).put("text",text).put("reference",reference?:JSONObject.NULL)
fun ConversationOutboxEntry.outgoing()=OutgoingMessage(id,"personal-main",text,reference,
 if(state=="accepted")"sent" else if(state=="queued_local")"queued_local" else if(state in setOf("prepared","sending"))"sending" else "unknown",serverId,createdAt=createdAt)

/** Only exact server identities settle an uncertain local send, never matching body text. */
fun reconcileConversationOutbox(entries:List<ConversationOutboxEntry>,messages:List<JSONObject>):List<ConversationOutboxEntry> = entries.map{entry->
 val receipt=messages.firstOrNull{message->message.optString("role")=="user"&&(
  message.optString("request_id")==entry.id||entry.serverId.isNotBlank()&&message.optString("id")==entry.serverId)}
 if(receipt==null)entry else entry.copy(state="accepted",serverId=receipt.optString("id"))
}
