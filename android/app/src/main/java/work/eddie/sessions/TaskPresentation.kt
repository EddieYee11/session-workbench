package work.eddie.sessions

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import android.content.Intent
import android.net.Uri
import org.json.JSONObject

/** Counts only recorded completed calls; started/failed calls never claim completion. */
fun stepCategory(tool:String):String=when{
 tool.lowercase().contains("search")->"search"
 tool.lowercase() in setOf("read","read_file","readfile")->"read"
 tool.lowercase() in setOf("edit","write","write_file","apply_patch")->"edit"
 tool.lowercase() in setOf("bash","shell","exec_command")->"command"
 else->"other"
}
fun stepText(kind:String,category:String,count:Int):String=when(kind){
 "tool.started"->"开始操作 · 结果尚未确认"
 "tool.failed"->"操作失败 · 查看原始记录"
 "tool.completed"->when(category){
  "search"->"完成 $count 次搜索"
  "read"->"读取文件 $count 次"
  "edit"->"完成 $count 次文件修改"
  "command"->"运行了 $count 条命令 · 结果见记录"
  else->"执行了 $count 项操作"
 }
 "waiting","approval_required"->"等待你的回应"
 else->ledgerEventLabel(kind)
}
fun humanSteps(events:List<JSONObject>):List<LedgerEvent>{
 val rows=mutableListOf<LedgerEvent>()
 var lastCategory="";var count=0
 val finishedIds=events.filter{it.optString("kind") in setOf("tool.completed","tool.failed")}.mapNotNull{runCatching{JSONObject(it.optString("text")).optString("call_id").takeIf{v->v.isNotBlank()}}.getOrNull()}.toSet()
 events.filterNot{it.optString("kind")=="tool.started"&&runCatching{JSONObject(it.optString("text")).optString("call_id") in finishedIds}.getOrDefault(false)}.forEach{e->
  val kind=e.optString("kind");val raw=e.optString("text")
  val data=runCatching{JSONObject(raw)}.getOrNull()
  val category=stepCategory(data?.optString("tool").orEmpty())
  val detail=if(kind.startsWith("tool."))"工具：${data?.optString("tool").orEmpty().ifBlank{"未记录"}}\n参数／输出摘要：${data?.optString("summary").orEmpty().ifBlank{"未记录；不能推断成功结果"}}\n原始事件：$raw" else raw
  if(kind=="tool.completed"&&lastCategory==category&&rows.isNotEmpty()){
   count++;val old=rows.removeAt(rows.lastIndex)
   rows+=LedgerEvent(stepText(kind,category,count),e.optDouble("at"),old.detail+"\n"+detail)
  }else{
   count=1;rows+=LedgerEvent(stepText(kind,category,1),e.optDouble("at"),detail)
  }
  lastCategory=if(kind=="tool.completed")category else ""
 }
 return rows
}
fun ledgerArtifacts(record:JSONObject):List<JSONObject>{
 val a=record.optJSONArray("artifacts")?:record.optJSONObject("structured_result")?.optJSONArray("artifacts")?:return emptyList()
 return (0 until a.length()).mapNotNull{i->
  when(val x=a.opt(i)){is JSONObject->x;is String->JSONObject().put("path",x);else->null}
 }.filter{listOf("path","url","reference","summary").any{k->it.optString(k).isNotBlank()}}.distinctBy{it.toString()}
}
@Composable fun ArtifactCards(artifacts:List<JSONObject>){
 if(artifacts.isEmpty())return
 var actionError by remember{mutableStateOf("")}
 val clip=LocalClipboardManager.current;val context=LocalContext.current
 Column(Modifier.fillMaxWidth().padding(top=10.dp)){
  if(actionError.isNotBlank())Text(actionError,fontSize=Type.Caption,color=AmberText)
  Text("产物",fontSize=Type.Caption,color=Muted)
  artifacts.forEach{a->
   val target=a.optString("url").ifBlank{a.optString("path").ifBlank{a.optString("reference")}}
   Text(a.optString("name").ifBlank{target.substringAfterLast('/').ifBlank{"报告／总结"}},fontSize=Type.BodySm,color=Ink)
   Text(target.ifBlank{a.optString("summary")},fontSize=Type.Caption,color=Muted)
   Row{
    if(target.isNotBlank())TextButton(onClick={clip.setText(AnnotatedString(target))}){Text("复制")}
    if(target.startsWith("https://")||target.startsWith("http://")){
     TextButton(onClick={runCatching{context.startActivity(Intent(Intent.ACTION_VIEW,Uri.parse(target)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}.onFailure{actionError="无法打开链接，请复制后查看"}}){Text("打开")}
     TextButton(onClick={runCatching{context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT,target),"分享链接").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))}.onFailure{actionError="分享未打开，可复制链接"}}){Text("分享")}
    }else if(target.isNotBlank())Text("远端文件路径",fontSize=Type.Micro,color=Muted)
   }
  }
 }
}
