package work.eddie.sessions

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Calendar
import java.util.UUID

data class LedgerEntry(val id:String,val ts:Long,val amount:Double,val category:String,val note:String,val kind:String)

val LedgerCategories=listOf("餐饮","交通","购物","娱乐","日用","其他")

class LedgerStore(context:Context){
 private val file=File(context.filesDir,"ledger.json").apply{if(!exists())writeText("[]")}
 private var cache:List<LedgerEntry>?=null
 fun entries():List<LedgerEntry>{cache?.let{return it}
  val list=runCatching{JSONArray(file.readText())}.getOrDefault(JSONArray()).objects()
   .map{LedgerEntry(it.optString("id"),it.optLong("ts"),it.optDouble("amount"),it.optString("category","其他"),it.optString("note",""),it.optString("kind","out"))}
   .sortedByDescending{it.ts}
  cache=list;return list}
 private fun save(list:List<LedgerEntry>){
  file.writeText(JSONArray(list.map{JSONObject().put("id",it.id).put("ts",it.ts).put("amount",it.amount).put("category",it.category).put("note",it.note).put("kind",it.kind)}).toString())
  cache=list}
 fun add(amount:Double,category:String,note:String,kind:String="out"):LedgerEntry{
  val e=LedgerEntry(UUID.randomUUID().toString(),System.currentTimeMillis(),amount,category,note,kind)
  val list=(entries()+e).sortedByDescending{it.ts};save(list);return e}
 fun delete(id:String){save(entries().filter{it.id!=id})}
 private fun dayStart(ts:Long)=Calendar.getInstance().apply{timeInMillis=ts;set(Calendar.HOUR_OF_DAY,0);set(Calendar.MINUTE,0);set(Calendar.SECOND,0);set(Calendar.MILLISECOND,0)}.timeInMillis
 fun todayOut():Double{val s=dayStart(System.currentTimeMillis());return entries().filter{it.kind=="out"&&it.ts>=s}.sumOf{it.amount}}
 fun monthOut():Double{val s=Calendar.getInstance().apply{set(Calendar.DAY_OF_MONTH,1);set(Calendar.HOUR_OF_DAY,0);set(Calendar.MINUTE,0);set(Calendar.SECOND,0);set(Calendar.MILLISECOND,0)}.timeInMillis;return entries().filter{it.kind=="out"&&it.ts>=s}.sumOf{it.amount}}
}

fun money(v:Double)=if(v==v.toLong().toDouble())"¥${v.toLong()}" else "¥${"%.2f".format(v)}"
