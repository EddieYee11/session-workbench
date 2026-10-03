package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONObject
import java.math.BigDecimal
import java.text.NumberFormat
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

private val localZone=ZoneId.of("Asia/Shanghai")

/** The Dashboard contract uses integer minor units for each account currency. */
fun formatMinorAmount(minor:Long,currency:String):String{
 val number=NumberFormat.getNumberInstance(Locale.CHINA).apply{minimumFractionDigits=2;maximumFractionDigits=2}
 return "${currency.ifBlank{"币种未知"}} ${number.format(BigDecimal.valueOf(minor,2))}"
}

fun eventStart(event:JSONObject):Instant?=runCatching{
 val start=event.optJSONObject("start")?:return null
 when{
  start.optString("dateTime").isNotBlank()->OffsetDateTime.parse(start.getString("dateTime")).toInstant()
  start.optString("date").isNotBlank()->LocalDate.parse(start.getString("date")).atStartOfDay(localZone).toInstant()
  else->null
 }
}.getOrNull()

fun nextEvent(events:List<JSONObject>,now:Instant=Instant.now()):JSONObject?=events
 .filter{event->
  val start=eventStart(event)?:return@filter false
  val end=event.optJSONObject("end")?.let{JSONObject().put("start",it)}?.let(::eventStart)
  start>=now || end!=null&&end>now
 }.minByOrNull{eventStart(it)?:Instant.MAX}

private fun eventTime(event:JSONObject):String{
 val start=eventStart(event)?:return "时间未提供"
 val day=start.atZone(localZone)
 val allDay=event.optJSONObject("start")?.optString("date").orEmpty().isNotBlank()
 return if(allDay)day.format(DateTimeFormatter.ofPattern("M月d日 E",Locale.CHINA))+" · 全天"
 else day.format(DateTimeFormatter.ofPattern("M月d日 E HH:mm",Locale.CHINA))
}

private fun updateTime(ts:Double):String=if(ts<=0)"更新时间未知" else runCatching{
 Instant.ofEpochMilli((ts*1000).toLong()).atZone(localZone)
  .format(DateTimeFormatter.ofPattern("M月d日 HH:mm",Locale.CHINA))
}.getOrDefault("更新时间未知")

private fun sourceProblem(code:String):String=when(code){
 "upstream_auth_failed"->"来源授权已失效"
 "credential_missing","credential_permissions"->"来源尚未配置"
 "upstream_timeout"->"来源响应超时"
 "upstream_unavailable","source_unavailable"->"来源暂不可用"
 else->"暂时无法读取来源数据"
}

private fun scopeText(calendar:JSONObject):String{
 val coverage=calendar.optJSONObject("coverage")?:return "日历范围未说明"
 val days=coverage.optInt("days")
 val scope=when(coverage.optString("scope")){
  "configured_calendar_only"->"仅已配置日历"
  else->"日历范围待核对"
 }
 return if(days>0)"$scope · 未来${days}天" else scope
}

@Composable fun PersonalSourceCards(vm:WorkbenchModel,open:(String)->Unit){
 val overview=vm.personal
 val calendar=overview.optJSONObject("calendar")?:JSONObject()
 val finance=overview.optJSONObject("finance")?:JSONObject()
 val hasSnapshot=overview.has("generated_at")
 BoxWithConstraints(Modifier.fillMaxWidth()){
  if(maxWidth>=500.dp)Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){
   Box(Modifier.weight(1f)){PhoneCalendarCard(compact=true)}
   Box(Modifier.weight(1f)){FinanceOverviewCard(finance,vm.personalFresh,hasSnapshot,true){open("finance")}}
  }else Row(Modifier.horizontalScroll(rememberScrollState()),horizontalArrangement=Arrangement.spacedBy(10.dp)){
   Box(Modifier.width(285.dp)){PhoneCalendarCard(compact=true)}
   Box(Modifier.width(285.dp)){FinanceOverviewCard(finance,vm.personalFresh,hasSnapshot,true){open("finance")}}
  }
 }
}

@Composable fun PersonalDetailPage(vm:WorkbenchModel,page:String,back:()->Unit){
 val overview=vm.personal
 val calendar=overview.optJSONObject("calendar")?:JSONObject()
 val finance=overview.optJSONObject("finance")?:JSONObject()
 val hasSnapshot=overview.has("generated_at")
 Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal=20.dp,vertical=12.dp),horizontalAlignment=Alignment.CenterHorizontally){
  Column(Modifier.widthIn(max=820.dp).fillMaxWidth()){
   Row(verticalAlignment=Alignment.CenterVertically){
    IconButton(onClick=back){ComIcon(R.drawable.com_icon_back_v1,"返回",Modifier.size(24.dp))}
    ComIcon(if(page=="calendar")R.drawable.com_icon_today_v1 else R.drawable.com_icon_finance_v1,null,Modifier.size(24.dp))
    Text(if(page=="calendar")"日历"else"账本",Modifier.weight(1f).padding(start=3.dp),fontSize=23.sp,fontWeight=FontWeight.SemiBold,color=Ink)
    IconButton(onClick={vm.refreshPersonalNow()},enabled=!vm.personalLoading&&vm.store.token.isNotEmpty()){ComIcon(R.drawable.com_icon_refresh_v1,"刷新来源",Modifier.size(24.dp),alpha=if(vm.personalLoading).5f else 1f)}
   }
   Text(if(vm.personalFresh)"概览生成于 ${updateTime(overview.optDouble("generated_at"))}" else if(hasSnapshot)"离线缓存 · 保存于 ${updateTime(overview.optDouble("generated_at"))}" else "正在连接数据来源",Modifier.padding(start=54.dp,bottom=14.dp),fontSize=Type.Caption,color=if(vm.personalFresh)Muted else AmberText)
   if(vm.personalError.isNotBlank()&&!vm.personalFresh)Text(vm.personalError,Modifier.padding(bottom=10.dp),fontSize=Type.Caption,color=AmberText)
   if(page=="calendar")CalendarOverviewCard(calendar,vm.personalFresh,hasSnapshot,false){}
   else FinanceOverviewCard(finance,vm.personalFresh,hasSnapshot,false){}
  }
 }
}

private fun financeTodayExpense(finance:JSONObject):String{
 val totals=finance.optJSONObject("totals")?:return ""
 val currency=totals.keys().asSequence().toList().sorted().singleOrNull()?:return ""
 val row=totals.optJSONObject(currency)?:return ""
 return "今日支出 ${formatMinorAmount(row.optLong("today_expense_minor"),currency)}"
}

private fun todayDateLabel():String=runCatching{
 LocalDate.now(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("M月d日 EEEE",Locale.CHINA))
}.getOrDefault("")

/** 页头一句话替代原技术副标题：先告诉你今天要做什么决定。 */
@Composable private fun TodayStatusLine(vm:WorkbenchModel){
 val finance=vm.personal.optJSONObject("finance")?:JSONObject()
 val decisions=todayDecisionItems(vm).count{!it.signals}
 val ongoing=todayOngoingTasks(vm).size
 val parts=mutableListOf("${decisions} 件待你决定","${ongoing} 件在执行")
 val expense=if(finance.optBoolean("available"))financeTodayExpense(finance) else ""
 if(expense.isNotBlank())parts+=expense
 Text(parts.joinToString(" · "),Modifier.padding(top=6.dp,bottom=14.dp),fontSize=Type.Caption,color=if(decisions>0)Ink else Muted)
}

/** 账本降为一行数字，不再占一张卡。 */
@Composable private fun FinanceSummaryLine(finance:JSONObject,fresh:Boolean,hasSnapshot:Boolean,open:()->Unit){
 val available=finance.optBoolean("available")
 val totals=finance.optJSONObject("totals")?:JSONObject()
 val currencies=totals.keys().asSequence().toList().sorted()
 val currency=currencies.firstOrNull()
 val row=currency?.let{totals.optJSONObject(it)}?:JSONObject()
 val summary=when{
  !hasSnapshot->"连接后读取 ezBookkeeping 月概况"
  !available->sourceProblem(finance.optString("error_code"))
  currency==null->"本月暂无记账数据"
  else->"本月支出 ${formatMinorAmount(row.optLong("expense_minor"),currency)} · 今日 ${formatMinorAmount(row.optLong("today_expense_minor"),currency)}"+(if(currencies.size>1)" · 等 ${currencies.size} 种币种" else "")
 }
 PolishCard(Modifier.fillMaxWidth(),onClick=open){
  Row(Modifier.padding(horizontal=18.dp,vertical=16.dp),verticalAlignment=Alignment.CenterVertically){
   ComIcon(R.drawable.com_icon_finance_v1,null,Modifier.size(22.dp))
   Column(Modifier.weight(1f).padding(start=10.dp)){
    Text("本月账本",fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=Ink)
    Text(summary,Modifier.padding(top=2.dp),fontSize=Type.Caption,color=if(hasSnapshot&&available)Muted else AmberText,maxLines=1,overflow=TextOverflow.Ellipsis)
   }
   ComIcon(R.drawable.com_icon_chevron_v1,"打开账本",Modifier.size(20.dp))
  }
 }
 if(hasSnapshot&&available)SourceLine(finance.optString("source","ezBookkeeping"),finance,fresh)
}

/** 今天只回答一个问题：我现在要做什么决定。 */
@Composable fun PersonalSourcesPage(
 vm:WorkbenchModel,
 openTask:(String,String)->Unit,
 openTasks:(String)->Unit,
 openDetail:(String)->Unit,
 openSignals:()->Unit,
 openMore:()->Unit,
){
 val overview=vm.personal
 val finance=overview.optJSONObject("finance")?:JSONObject()
 val hasSnapshot=overview.has("generated_at")
 Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal=20.dp,vertical=12.dp),horizontalAlignment=Alignment.CenterHorizontally){
  Column(Modifier.widthIn(max=820.dp).fillMaxWidth()){
   Row(verticalAlignment=Alignment.CenterVertically){
    Text("今天${todayDateLabel().let{if(it.isBlank())"" else " · $it"}}",Modifier.weight(1f),fontSize=23.sp,fontWeight=FontWeight.SemiBold,color=Ink)
    IconButton(onClick={vm.refreshPersonalNow()},enabled=!vm.personalLoading&&vm.store.token.isNotEmpty()){ComIcon(R.drawable.com_icon_refresh_v1,"刷新来源",Modifier.size(24.dp),alpha=if(vm.personalLoading).5f else 1f)}
    IconButton(onClick=openMore){ComIcon(R.drawable.com_icon_menu_v1,"更多",Modifier.size(24.dp))}
   }
   if(vm.personalError.isNotBlank()&&!vm.personalFresh)Text(vm.personalError,Modifier.padding(top=6.dp),fontSize=Type.Caption,color=AmberText)
   TodayStatusLine(vm)
   TodayDecisionCard(vm,openTask){openTasks("decision")}
   Spacer(Modifier.height(14.dp))
   TodayTimelineCard{openDetail("calendar")}
   Spacer(Modifier.height(14.dp))
   TodayWorkLine(vm,{openTasks("active")},{openTasks("all")})
   Spacer(Modifier.height(14.dp))
   FinanceSummaryLine(finance,vm.personalFresh,hasSnapshot){openDetail("finance")}
   TodayAwarenessCard(vm,openSignals)
  }
 }
}

@Composable private fun SourceLine(label:String,source:JSONObject,fresh:Boolean){
 val available=source.optBoolean("available")
 val note=when{
  !available->sourceProblem(source.optString("error_code"))
  !fresh->"缓存 · 来源更新于 ${updateTime(source.optDouble("updated_at"))}"
  source.optBoolean("stale")->"来源数据已过期 · 更新于 ${updateTime(source.optDouble("updated_at"))}"
  else->"更新于 ${updateTime(source.optDouble("updated_at"))}"
 }
 Text("$label · $note",fontSize=Type.Caption,lineHeight=17.sp,color=if(available&&fresh&&!source.optBoolean("stale"))Muted else AmberText)
}

@Composable private fun CalendarOverviewCard(calendar:JSONObject,fresh:Boolean,hasSnapshot:Boolean,compact:Boolean,open:()->Unit){
 val available=calendar.optBoolean("available")
 val events=calendar.array("items").sortedBy{eventStart(it)?:Instant.MAX}
 val upcoming=nextEvent(events)
 PolishCard(Modifier.fillMaxWidth(),onClick=if(compact)open else null){
  Column(Modifier.padding(20.dp)){
   Row(verticalAlignment=Alignment.CenterVertically){ComIcon(R.drawable.com_icon_today_v1,null,Modifier.size(24.dp));Text(if(compact)"下一项日程"else"日历 · 近期日程",Modifier.weight(1f).padding(start=5.dp),fontSize=17.sp,fontWeight=FontWeight.SemiBold,color=Ink);if(compact)ComIcon(R.drawable.com_icon_chevron_v1,"打开日历",Modifier.size(23.dp))}
   Spacer(Modifier.height(15.dp))
   if(!hasSnapshot)Text("连接后读取已配置的日历",fontSize=Type.BodySm,color=Muted)
   else if(!available)Text(sourceProblem(calendar.optString("error_code")),fontSize=Type.BodySm,color=AmberText)
   else if(compact){
    Text(upcoming?.optString("title")?:"当前范围内没有即将到来的日程",fontSize=Type.Body,fontWeight=FontWeight.Medium,color=Ink,maxLines=2,overflow=TextOverflow.Ellipsis)
    if(upcoming!=null)Text(eventTime(upcoming),Modifier.padding(top=5.dp),fontSize=Type.BodySm,color=Muted)
   }else if(events.isEmpty())Text("当前范围内暂无日程",fontSize=Type.BodySm,color=Muted)
   else events.forEachIndexed{index,event->
    if(index>0)HorizontalDivider(Modifier.padding(vertical=11.dp),color=Line)
    Text(event.optString("title","未命名日程"),fontSize=Type.Body,fontWeight=FontWeight.Medium,color=Ink)
    Text(eventTime(event),Modifier.padding(top=3.dp),fontSize=Type.Caption,color=Muted)
   }
   Spacer(Modifier.height(14.dp))
   if(hasSnapshot)SourceLine(calendar.optString("source","Google Calendar"),calendar,fresh)
   Text(if(hasSnapshot&&available)scopeText(calendar) else "日历范围待连接后核对",Modifier.padding(top=3.dp),fontSize=Type.Caption,color=Faint)
  }
 }
}

@Composable private fun FinanceOverviewCard(finance:JSONObject,fresh:Boolean,hasSnapshot:Boolean,compact:Boolean,open:()->Unit){
 val available=finance.optBoolean("available")
 val totals=finance.optJSONObject("totals")?:JSONObject()
 val currencies=totals.keys().asSequence().toList().sorted()
 PolishCard(Modifier.fillMaxWidth(),onClick=if(compact)open else null){
  Column(Modifier.padding(20.dp)){
   Row(verticalAlignment=Alignment.CenterVertically){ComIcon(R.drawable.com_icon_finance_v1,null,Modifier.size(24.dp));Text("本月账本",Modifier.weight(1f).padding(start=5.dp),fontSize=17.sp,fontWeight=FontWeight.SemiBold,color=Ink);if(compact)ComIcon(R.drawable.com_icon_chevron_v1,"打开账本",Modifier.size(23.dp))}
   Spacer(Modifier.height(15.dp))
   if(!hasSnapshot)Text("连接后读取 ezBookkeeping 月概况",fontSize=Type.BodySm,color=Muted)
   else if(!available)Text(sourceProblem(finance.optString("error_code")),fontSize=Type.BodySm,color=AmberText)
   else if(currencies.isEmpty())Text("本月暂无记账数据",fontSize=Type.BodySm,color=Muted)
   else currencies.forEachIndexed{index,currency->
    if(index>0)HorizontalDivider(Modifier.padding(vertical=12.dp),color=Line)
    val row=totals.optJSONObject(currency)?:JSONObject()
    Text(currency,fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=Muted)
    Text("支出 ${formatMinorAmount(row.optLong("expense_minor"),currency)}",Modifier.padding(top=5.dp),fontSize=Type.Body,fontWeight=FontWeight.SemiBold,color=Ink)
    Text("收入 ${formatMinorAmount(row.optLong("income_minor"),currency)} · 今日支出 ${formatMinorAmount(row.optLong("today_expense_minor"),currency)}",Modifier.padding(top=4.dp),fontSize=Type.Caption,lineHeight=18.sp,color=Muted)
   }
   if(available){
    Text("${finance.optString("month")} · ${finance.optInt("month_transaction_count")} 笔 · 本月至今",Modifier.padding(top=13.dp),fontSize=Type.Caption,color=Faint)
    if(finance.optJSONObject("coverage")?.optString("totals")=="all_fetched_transactions_month_to_date")Text("汇总覆盖全部可获取的本月交易",Modifier.padding(top=3.dp),fontSize=Type.Caption,color=Faint)
   }
   Spacer(Modifier.height(10.dp))
   if(hasSnapshot)SourceLine(finance.optString("source","ezBookkeeping"),finance,fresh)
  }
 }
}
