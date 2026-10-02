package work.eddie.sessions

import org.json.JSONObject

/** Local sends keep one visual identity until the native transcript catches up. */
data class OutgoingMessage(
 val id:String,val scope:String,val text:String,val reference:JSONObject?=null,
 val status:String="sending",val serverId:String="",val previousIds:Set<String> = emptySet(),
 val createdAt:Double=System.currentTimeMillis()/1000.0,
)

fun messageMotionId(message:JSONObject):String{
 fun value(key:String)=if(message.isNull(key))""else message.optString(key).takeUnless{it=="null"}.orEmpty()
 return value("motion_id").ifBlank{value("request_id").ifBlank{value("id")}}
}

fun mergeOutgoingMessages(messages:List<JSONObject>,outgoing:List<OutgoingMessage>):List<JSONObject>{
 val rows=messages.map{JSONObject(it.toString())}.toMutableList()
 val claimed=mutableSetOf<Int>()
 outgoing.forEach{sent->
  val exact=rows.indices.firstOrNull{i->i !in claimed&&rows[i].optString("role")=="user"&&(
   rows[i].optString("request_id")==sent.id||sent.serverId.isNotBlank()&&rows[i].optString("id")==sent.serverId
  )}
  // The server binds native echo identities to this request. Identical body text
  // and client/server clocks cannot establish that two rows are the same send.
  val match=exact?:-1
  if(match>=0){
   claimed.add(match)
   rows[match].put("motion_id",sent.id)
   if(sent.reference!=null&&!rows[match].has("reference"))rows[match].put("reference",sent.reference)
   if(!rows[match].has("status"))rows[match].put("delivery_status","sent")
  }else{
   rows.add(JSONObject().put("id",sent.id).put("motion_id",sent.id).put("role","user").put("text",sent.text)
    .put("status",sent.status).put("phase",if(sent.status=="sending")"sending" else "")
    .put("created_at",sent.createdAt).put("reference",sent.reference?:JSONObject.NULL).put("local",true))
  }
 }
 return rows
}

fun messageReference(message:JSONObject,mode:String,agent:String,scope:String)=JSONObject()
 .put("mode",mode).put("id",message.optString("id"))
 .put("author",if(message.optString("role")=="user")"你"else agent)
 .put("text",message.optString("text").take(2000)).put("source_session_id",scope)
