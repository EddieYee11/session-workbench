package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

private fun JSONObject.safeText(key:String):String=if(isNull(key))"" else optString(key).takeIf{it!="null"}.orEmpty()
private fun inspectionTime(seconds:Double):String=if(seconds<=0)"尚无" else runCatching{
 Instant.ofEpochMilli((seconds*1000).toLong()).atZone(ZoneId.of("Asia/Shanghai"))
  .format(DateTimeFormatter.ofPattern("M月d日 HH:mm",Locale.CHINA))
}.getOrDefault("时间未知")

@Composable fun SignalActivitySection(vm:WorkbenchModel){
 val health=vm.signalsHealth
 val items=vm.signals.array("items")
 val hasHealth=health.has("interval_minutes")
 HorizontalDivider(Modifier.padding(top=10.dp,bottom=18.dp),color=Line)
 Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween){
  Text("手机通知巡检",fontSize=18.sp,fontWeight=FontWeight.SemiBold,color=Ink)
  TextButton(onClick={vm.refreshSignalsNow()},enabled=!vm.signalsLoading&&vm.store.token.isNotEmpty()){
   Text(if(vm.signalsLoading)"刷新中"else"刷新",fontSize=12.sp)
  }
 }
 if(!hasHealth&&items.isEmpty()){
  Text(if(vm.signalsLoading)"正在读取通知活动…"else"暂无通知巡检记录",fontSize=13.sp,color=Muted)
 }else{
  Text("重要 ${health.optInt("important")} · 待巡检 ${health.optInt("pending")} · 已分析 ${health.optInt("reviewed")}",fontSize=13.sp,color=Ink)
  val interval=health.optInt("interval_minutes",30).coerceAtLeast(1)
  val attempt=health.optDouble("last_attempt")
  val elapsed=if(attempt>0)((System.currentTimeMillis()/1000-attempt)/60).toInt().coerceAtLeast(0) else 0
  Text("最近完成 ${inspectionTime(health.optDouble("last_success"))} · 最近尝试 ${inspectionTime(attempt)}",Modifier.padding(top=4.dp),fontSize=11.sp,color=Muted)
  Text("Mac mini 计划每 ${interval} 分钟巡检；${if(attempt>0)"距上次尝试 ${elapsed} 分钟"else"尚未开始巡检"}${if(attempt>0&&elapsed>interval+10)"，可能延迟"else""}",Modifier.padding(top=3.dp),fontSize=11.sp,color=if(attempt>0&&elapsed>interval+10)AmberText else Muted)
  if(health.safeText("last_error").isNotBlank())Text("最近巡检异常：${health.safeText("last_error")}",Modifier.padding(top=4.dp),fontSize=11.sp,color=AmberText)
  if(!vm.signalsFresh||!vm.signalsHealthFresh)Text("部分状态来自上次保存的记录",Modifier.padding(top=4.dp),fontSize=11.sp,color=AmberText)
  if(vm.signalsError.isNotBlank())Text(vm.signalsError,Modifier.padding(top=4.dp),fontSize=11.sp,color=AmberText)
  if(items.isEmpty())Text("尚无可查看的通知摘要",Modifier.padding(top=12.dp),fontSize=12.sp,color=Muted)
  else items.take(12).forEach{item->
   val important=item.safeText("priority")=="important"
   val reviewed=item.safeText("status")=="reviewed"
   Surface(Modifier.fillMaxWidth().padding(top=10.dp),shape=RoundedCornerShape(Radii.L),color=Card,border=BorderStroke(1.dp,Line)){
    Column(Modifier.padding(14.dp)){
     Text((if(important)"重要 · "else if(!reviewed)"待巡检 · "else"")+item.safeText("package_name"),fontSize=11.sp,fontWeight=FontWeight.SemiBold,color=if(important)AmberText else Muted)
     Text(if(reviewed)item.safeText("summary").ifBlank{"已完成分析"} else "等待 Mac mini 巡检",Modifier.padding(top=5.dp),fontSize=14.sp,lineHeight=20.sp,color=Ink)
     if(reviewed&&item.safeText("suggested_record").isNotBlank())Text("建议记录：${item.safeText("suggested_record")}",Modifier.padding(top=7.dp),fontSize=12.sp,lineHeight=18.sp,color=Muted)
     if(reviewed&&item.safeText("draft_reply").isNotBlank())Text("回复草稿（仅供查看）：${item.safeText("draft_reply")}",Modifier.padding(top=7.dp),fontSize=12.sp,lineHeight=18.sp,color=Ink)
     Text("通知 ${inspectionTime(item.optLong("posted_at_ms")/1000.0)} · 巡检 ${inspectionTime(item.optDouble("inspected_at"))}",Modifier.padding(top=8.dp),fontSize=10.sp,color=Faint)
    }
   }
  }
 }
}
