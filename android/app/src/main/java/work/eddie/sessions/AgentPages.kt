package work.eddie.sessions

import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.ui.Alignment
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.*
import org.json.*
import java.util.UUID

@Composable internal fun AgentSharedComposer(vm:WorkbenchModel){
 if(LocalPersonalDockEnabled.current)return
 val motion=rememberMessageSendMotionState()
 val focus=remember{FocusRequester()}
 Column(Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=6.dp)){
  vm.linkedMatter?.let{r->Row(Modifier.fillMaxWidth()){Text("关联事项 · ${r.optString("title")}",Modifier.weight(1f),color=Muted);TextButton(onClick={vm.linkedMatter=null}){Text("取消")}}}
  HermesComposer(vm,vm.store.token.isNotBlank(),motion,focus)
 }
}
@Composable private fun AgentCard(title:String,content:@Composable ColumnScope.()->Unit){
 Surface(Modifier.fillMaxWidth(),shape=RoundedCornerShape(24.dp),color=Card){
  Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){Text(title,fontWeight=FontWeight.SemiBold,color=Ink);content()}
 }
}
@OptIn(ExperimentalLayoutApi::class)
@Composable fun AgentTodayPage(vm:WorkbenchModel,chat:()->Unit,connections:()->Unit,devices:()->Unit,openTasks:()->Unit){
 var data by remember{mutableStateOf(vm.store.cachedSecure("personal-briefing"))};var busy by remember{mutableStateOf(false)};var note by remember{mutableStateOf("")};val scope=rememberCoroutineScope()
 var correcting by remember{mutableStateOf<JSONObject?>(null)};var correction by remember{mutableStateOf("")}
 suspend fun refresh(){try{data=vm.store.request("/personal/briefing");vm.store.secureCache("personal-briefing",data);note=""}catch(e:Exception){note=e.message.orEmpty()}}
 LaunchedEffect(Unit){refresh();while(true){delay(30000);refresh()}}
 val cards=data.array("cards")
 val sourceKeys=data.optJSONObject("source_status")?.array("sources")?.map{it.optString("name")}?.filter{it.isNotBlank()}?:emptyList()
 val pending=todayDecisionItems(vm).size
 Column(Modifier.fillMaxSize()){
  Row(Modifier.fillMaxWidth().padding(16.dp),verticalAlignment=Alignment.CenterVertically){Text("今天",Modifier.weight(1f),fontSize=28.sp,fontWeight=FontWeight.Normal);RoundIcon(ReferenceIcons.Sliders,"设置与数据连接",connections)}
  Box(Modifier.weight(1f).fillMaxWidth()){
   Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal=16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
   EnterAnim{Column(Modifier.fillMaxWidth().padding(top=10.dp,bottom=2.dp),horizontalAlignment=Alignment.CenterHorizontally){
    Text("你好，Eddie",fontSize=22.sp,fontWeight=FontWeight.SemiBold,color=Ink)
    Text(todayGreeting(cards.size,note.isNotBlank()),Modifier.padding(top=10.dp),fontSize=Type.Body,color=Muted,textAlign=TextAlign.Center,lineHeight=24.sp)
   }}
   SoftCard(Modifier.fillMaxWidth()){
    SourceBadgeRow(sourceKeys,Modifier.align(Alignment.CenterHorizontally))
    Text(todaySourceCaption(sourceKeys),Modifier.fillMaxWidth().padding(top=14.dp),fontSize=Type.BodySm,color=Muted,textAlign=TextAlign.Center,maxLines=2,overflow=TextOverflow.Ellipsis)
    Text(todayBriefingBody(),Modifier.fillMaxWidth().padding(top=18.dp),fontSize=Type.Body,color=Ink,lineHeight=26.sp)
   }
   if(note.isNotBlank())Text(note,color=AmberText)
   cards.forEach{card->AgentCard(card.optString("what",card.optString("title"))){
    if(card.has("assistant_suggestion"))Text("Hermes 建议",fontSize=Type.Caption,color=Faint)
    Text(card.optString("why"),color=Muted)
    Text("${sourceName(card.optString("source"))} · ${relTime(card.optDouble("source_updated_at"))}",fontSize=Type.Caption,color=Faint)
    card.optJSONObject("facts")?.let{Text(matterFactsText(it).take(450),fontSize=Type.BodySm,color=Muted)}
    card.optJSONObject("user_correction")?.let{Text("你的纠正：${it.optString("text")}",fontSize=Type.BodySm)}
    card.optJSONObject("grouping")?.let{group->
     Text("${if(group.optString("kind")=="user_link")"你关联的事项" else "关联推断"} · ${group.optString("reason")}",fontSize=Type.Caption,color=Muted)
     TextButton(onClick={scope.launch{runCatching{vm.store.request("/personal/matters/${card.optString("id")}/unlink",JSONObject());refresh()}.onFailure{note=it.message.orEmpty()}}}){Text("解除关联")}
    }
    Text(card.optString("next_step"),fontSize=Type.BodySm)
    FlowRow(horizontalArrangement=Arrangement.spacedBy(4.dp)){
     FilledTonalButton(onClick={vm.linkedMatter=card;chat()},shape=Radii.Pill){Icon(Icons.Outlined.ChatBubbleOutline,null,Modifier.size(17.dp));Text("继续处理",Modifier.padding(start=7.dp))}
     listOf("follow" to "关注","later" to "稍后","handled" to "已处理").forEach{(action,label)->TextButton(onClick={scope.launch{runCatching{vm.store.request("/personal/matters/${card.optString("id")}/feedback",JSONObject().put("action",action).put("request_id",UUID.randomUUID().toString()));refresh()}.onFailure{note=it.message.orEmpty()}}}){Text(label)}}
    }
    FlowRow{TextButton(onClick={correcting=card;correction=card.optJSONObject("user_correction")?.optString("text").orEmpty()}){Icon(Icons.Outlined.Edit,null,Modifier.size(16.dp));Text("纠错",Modifier.padding(start=6.dp))};TextButton(onClick={scope.launch{runCatching{vm.store.request("/personal/matters/${card.optString("id")}/feedback",JSONObject().put("action","mute").put("request_id",UUID.randomUUID().toString()));refresh()}.onFailure{note=it.message.orEmpty()}}}){Text("不再提醒")}}
   }}
   TextButton(onClick={scope.launch{busy=true;try{vm.store.request("/personal/sync",JSONObject().put("group","all"));refresh()}catch(e:Exception){note=e.message.orEmpty()}finally{busy=false}}},enabled=!busy){Text(if(busy)"正在更新…"else"更新个人事项")}
   val offline=data.optJSONObject("source_status")?.array("sources")?.filter{it.optString("status")!="connected"}?:emptyList()
   if(offline.isNotEmpty())Text(offline.joinToString(" · "){sourceName(it.optString("name"))+" "+connectionLabel(it.optString("status"))},fontSize=Type.Caption,lineHeight=17.sp,color=AmberText)
   // 悬浮胶囊压在滚动区底部，留出空档免得盖住最后一张卡。
   Spacer(Modifier.height(if(pending>0)64.dp else 12.dp))
   }
   if(pending>0)Box(Modifier.align(Alignment.BottomCenter).padding(bottom=10.dp)){
    FloatingPill("$pending 条待你决定",openTasks,leading=Icons.Outlined.Lightbulb)
   }
  }
  AgentSharedComposer(vm)
 }
 correcting?.let{card->AlertDialog(onDismissRequest={correcting=null},title={Text("纠正事项")},text={Column(verticalArrangement=Arrangement.spacedBy(12.dp)){Text(card.optString("title"),color=Muted);OutlinedTextField(correction,{correction=it},label={Text("正确的信息")},shape=RoundedCornerShape(16.dp));Text("原始来源会保留，你的纠正在后续分析和简报中优先使用。",fontSize=Type.Caption,color=Muted)}},confirmButton={TextButton(enabled=correction.isNotBlank(),onClick={scope.launch{runCatching{vm.store.request("/personal/matters/${card.optString("id")}/feedback",JSONObject().put("action","correct").put("text",correction).put("request_id",UUID.randomUUID().toString()));correcting=null;refresh()}.onFailure{note=it.message.orEmpty()}}}){Text("保存")}},dismissButton={TextButton(onClick={correcting=null}){Text("取消")}})}
}
private fun connectionLabel(value:String)=when(value){"connected"->"已连接";"needs_connection"->"需要授权";"unavailable"->"暂不可用";"not_synced"->"尚未同步";else->value}

// —— 今天页的参考图语汇：居中问候 + 来源图标行 + 简报正文 ——

private fun todayGreeting(cards:Int,failed:Boolean)=when{
 failed->"我是 Com。简报这次没取到，30 秒后自动重试。"
 cards==0->"我是 Com，正在为你准备第一份图文简报。"
 else->"我是 Com，今天有 $cards 件事值得你看一眼。"
}

private fun todaySourceCaption(keys:List<String>)=when{
 keys.isEmpty()->"连接数据源后，这里会列出每件事的出处…"
 keys.size<=2->"从 ${keys.joinToString("、"){sourceName(it)}} 了解你的日常规律…"
 else->"从 ${keys.take(2).joinToString("、"){sourceName(it)}} 等 ${keys.size} 个来源了解你的日常规律…"
}

private fun todayBriefingBody()="会把接下来有什么安排、发生了哪些变化、哪些事项值得留意整理成一页。\n这需要一点时间。准备的过程中我们随时可以聊；你今天最想解决的一件事是什么？"

/** 来源图标行：圆形图标彼此叠压并留白边，对应参考图简报卡顶部的应用图标。 */
@Composable private fun SourceBadgeRow(keys:List<String>,modifier:Modifier=Modifier){
 // 按图标去重：Gmail 与工作邮箱、苹果日历与 Google 日历本来就共用同一个符号。
 val shown=keys.ifEmpty{listOf("gmail","google_calendar","accounting","phone_health","com_task")}.distinctBy{sourceBadge(it).first}.take(5)
 val badge=52.dp;val step=42.dp
 Box(modifier.width(step*(shown.size-1)+badge).height(badge)){
  shown.forEachIndexed{i,key->
   val (icon,tint)=sourceBadge(key)
   Box(Modifier.offset(x=step*i).size(badge).background(tint,CircleShape).border(3.dp,Card,CircleShape),contentAlignment=Alignment.Center){
    Icon(icon,null,Modifier.size(24.dp),tint=Color.White)
   }
  }
 }
}

private fun sourceBadge(key:String):Pair<ImageVector,Color> = when(key){
 "gmail","work_mail"->Icons.Outlined.Mail to CompanionBlue
 "github"->Icons.Outlined.Code to Ink
 "apple_calendar","google_calendar","phone_calendar"->ReferenceIcons.Calendar to Danger
 "accounting"->Icons.Outlined.AccountBalanceWallet to Gold
 "garmin","phone_health"->Icons.Outlined.FavoriteBorder to PiGreen
 "com_task"->ReferenceIcons.Tasks to CompanionCoral
 else->Icons.Outlined.RadioButtonUnchecked to Faint
}
@Composable fun AgentMemoryPage(vm:WorkbenchModel){
 var data by remember{mutableStateOf(JSONObject())};var selected by remember{mutableStateOf("全部")};var editing by remember{mutableStateOf<JSONObject?>(null)};var text by remember{mutableStateOf("")};var note by remember{mutableStateOf("")};val scope=rememberCoroutineScope()
 var sourcesOpen by remember{mutableStateOf(false)}
 suspend fun refresh(){try{data=vm.store.request("/personal/memory")}catch(e:Exception){note=e.message.orEmpty()}}
 LaunchedEffect(Unit){refresh()}
 val items=data.array("items")
 val categories=(data.optJSONArray("categories")?.let{a->(0 until a.length()).map{a.getString(it)}}?:memoryCategories).ifEmpty{memoryCategories}
 val grouped=items.groupBy{it.optString("category").ifBlank{"关于我"}}
 val ordered=categories.sortedByDescending{grouped[it]?.size?:0}
 val featured=ordered.firstOrNull()
 val visible=items.filter{selected=="全部"||it.optString("category")==selected}
 val updatedAt=items.maxOfOrNull{it.optDouble("updated_at")}?:0.0
 Column(Modifier.fillMaxSize()){
  Row(Modifier.fillMaxWidth().padding(20.dp),verticalAlignment=Alignment.CenterVertically){Text("记忆",Modifier.weight(1f),fontSize=28.sp,fontWeight=FontWeight.Normal);RoundIcon(Icons.Outlined.MenuBook,"记忆来源"){sourcesOpen=true}}
  Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal=16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
   if(note.isNotBlank())Text(note,color=AmberText)
   MemoryUnderstandingCard(ordered.filter{grouped[it]?.isNotEmpty()==true},grouped,updatedAt,items.size)
   SoftSectionHeader("全部",Modifier.padding(top=8.dp,start=4.dp))
   if(featured!=null)MemoryCategoryCard(featured,grouped[featured]?:emptyList(),selected==featured,true,Modifier.fillMaxWidth()){
    selected=if(selected==featured)"全部" else featured
   }
   ordered.drop(1).chunked(2).forEach{pair->
    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(12.dp)){
     pair.forEach{category->
      MemoryCategoryCard(category,grouped[category]?:emptyList(),selected==category,false,Modifier.weight(1f)){
       selected=if(selected==category)"全部" else category
      }
     }
     if(pair.size==1)Spacer(Modifier.weight(1f))
    }
   }
   Text(if(selected=="全部")"全部 · ${visible.size} 条" else "$selected · ${visible.size} 条",Modifier.padding(top=10.dp,start=4.dp),fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=Muted)
   visible.forEach{r->SoftCard(Modifier.fillMaxWidth(),radius=Radii.Xxl,padding=PaddingValues(18.dp)){
    Text(r.optString("content"),fontSize=Type.Body,color=Ink,lineHeight=24.sp)
    Text("${if(r.optString("kind")=="inference")"推断"else"事实"} · 版本 ${r.optInt("version")} · ${relTime(r.optDouble("updated_at"))}",Modifier.padding(top=10.dp),fontSize=Type.Caption,color=Muted)
    val quote=r.optJSONObject("source")?.optString("quote").orEmpty()
    if(quote.isNotBlank())Text("来源：$quote",Modifier.padding(top=4.dp),fontSize=Type.Caption,color=Faint,maxLines=2,overflow=TextOverflow.Ellipsis)
    Row{TextButton(onClick={editing=r;text=r.optString("content")}){Text("纠正")};TextButton(onClick={scope.launch{try{vm.store.request("/personal/memory/${r.optString("id")}",JSONObject().put("request_id",UUID.randomUUID().toString()).put("expected_version",r.optInt("version")).put("archived",true));refresh()}catch(e:Exception){note=e.message.orEmpty()}}}){Text("归档")}}
   }}
   if(items.isEmpty())Text("还没有自动形成的分类记忆。现有 Markdown 资料仍可被召回。",color=Muted)
   Spacer(Modifier.height(12.dp))
  }
  AgentSharedComposer(vm)
 }
 editing?.let{r->AlertDialog(onDismissRequest={editing=null},title={Text("纠正记忆")},text={Column{OutlinedTextField(text,{text=it},label={Text("当前事实或偏好")});Text("来源和旧版本会保留，旧内容退出召回。",fontSize=Type.Caption)}},confirmButton={TextButton(onClick={scope.launch{try{vm.store.request("/personal/memory/${r.optString("id")}",JSONObject().put("request_id",UUID.randomUUID().toString()).put("expected_version",r.optInt("version")).put("content",text));editing=null;refresh()}catch(e:Exception){note=e.message.orEmpty()}}}){Text("保存")}},dismissButton={TextButton(onClick={editing=null}){Text("取消")}})}
 if(sourcesOpen)AlertDialog(onDismissRequest={sourcesOpen=false},title={Text("记忆来源")},text={Column(verticalArrangement=Arrangement.spacedBy(10.dp)){
  Text("当前显示 ${items.size} 条分类记忆。",color=Ink)
  Text("每条记忆保留来源、更新时间和修改历史。打开条目可查看原话并纠正。",color=Muted)
  Text("Markdown 保存事实；Hindsight 提供召回。",fontSize=Type.Caption,color=Faint)
 }},confirmButton={TextButton(onClick={sourcesOpen=false;scope.launch{refresh()}}){Text("更新记忆")}},dismissButton={TextButton(onClick={sourcesOpen=false}){Text("关闭")}})
}

// —— 记忆页的参考图语汇：长文了解卡 + 分类卡网格（图标徽标 / 元信息 / 统计瓦片）——

private val memoryCategories=listOf("关于我","工作","项目","生活","兴趣","健康","财务")

private fun memoryStamp(ts:Double):String=if(ts<=0)"时间未知" else runCatching{
 java.time.Instant.ofEpochMilli((ts*1000).toLong()).atZone(java.time.ZoneId.of("Asia/Shanghai"))
  .format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm"))
}.getOrDefault("时间未知")

private fun memoryBadge(category:String):Pair<ImageVector,Color> = when(category){
 "关于我"->Icons.Outlined.Person to CompanionCoral
 "工作"->ReferenceIcons.Work to CompanionBlue
 "项目"->Icons.Outlined.FolderOpen to PiGreen
 "生活"->Icons.Outlined.WbSunny to Gold
 "兴趣"->Icons.Outlined.AutoAwesome to AmberText
 "健康"->Icons.Outlined.FavoriteBorder to Danger
 "财务"->Icons.Outlined.AccountBalanceWallet to Ink
 else->Icons.Outlined.BookmarkBorder to Muted
}

/** 长文了解卡：把分类记忆拼成一篇「我对你的了解」，对应参考图顶部那张大卡。 */
@Composable private fun MemoryUnderstandingCard(ordered:List<String>,grouped:Map<String,List<JSONObject>>,updatedAt:Double,total:Int){
 SoftCard(Modifier.fillMaxWidth(),padding=PaddingValues(horizontal=20.dp,vertical=22.dp)){
  Text("我对 Eddie 的了解",fontSize=20.sp,fontWeight=FontWeight.SemiBold,color=Ink)
  Text(if(total==0)"还没有形成稳定的了解" else "更新于 ${memoryStamp(updatedAt)}",Modifier.padding(top=6.dp),fontSize=Type.Caption,color=Faint)
  if(total==0){
   Text("连接主对话后，稳定的事实与偏好会自动写进这里，每条都保留来源。",Modifier.padding(top=16.dp),fontSize=Type.Body,color=Muted,lineHeight=26.sp)
  }else ordered.take(3).forEach{category->
   val rows=grouped[category]?:emptyList()
   HorizontalDivider(Modifier.padding(top=18.dp,bottom=14.dp),color=Line)
   Text(category,fontSize=Type.Section,fontWeight=FontWeight.SemiBold,color=Ink)
   Text(rows.take(3).joinToString("\n"){it.optString("content")}.let{if(rows.size>3)it+" …" else it},
    Modifier.padding(top=8.dp),fontSize=Type.Body,color=Muted,lineHeight=26.sp)
  }
 }
}

/** 分类卡：featured 版带 2×2 统计瓦片（参考图的健康卡），其余是半宽卡。 */
@Composable private fun MemoryCategoryCard(category:String,rows:List<JSONObject>,active:Boolean,featured:Boolean,modifier:Modifier=Modifier,onClick:()->Unit){
 val (icon,tint)=memoryBadge(category)
 val facts=rows.count{it.optString("kind")!="inference"}
 val inferences=rows.size-facts
 val latest=rows.maxOfOrNull{it.optDouble("updated_at")}?:0.0
 val version=rows.maxOfOrNull{it.optInt("version")}?:0
 SoftCard(modifier,radius=Radii.Xxl,onClick=onClick,padding=PaddingValues(16.dp)){
  if(featured)Row(verticalAlignment=Alignment.CenterVertically){
   Column(Modifier.weight(1f).padding(end=10.dp)){
    IconBadge(icon,tint,size=44.dp)
    Text(category,Modifier.padding(top=12.dp),fontSize=Type.Section,fontWeight=FontWeight.SemiBold,color=Ink)
    Text("${rows.size} 条数据，$inferences 条推断",Modifier.padding(top=5.dp),fontSize=Type.Caption,color=Muted,maxLines=2)
    Text(if(latest>0)"更新于 ${relTime(latest)}" else "尚无记录",Modifier.padding(top=3.dp),fontSize=Type.Caption,color=Faint)
   }
   Column(Modifier.width(150.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
    Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){
     StatTile(Icons.Outlined.BookmarkBorder,"$facts 条事实",tint,Modifier.weight(1f))
     StatTile(Icons.Outlined.Lightbulb,"$inferences 条推断",Gold,Modifier.weight(1f))
    }
    Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){
     StatTile(Icons.Outlined.Schedule,if(latest>0)relTime(latest) else "--",Muted,Modifier.weight(1f))
     StatTile(Icons.Outlined.Layers,"v$version",tint,Modifier.weight(1f))
    }
   }
  }else{
   IconBadge(icon,tint,size=40.dp,iconSize=20.dp)
   Text(category,Modifier.padding(top=12.dp),fontSize=Type.Section,fontWeight=FontWeight.SemiBold,color=Ink,maxLines=1,overflow=TextOverflow.Ellipsis)
   Text(if(rows.isEmpty())"暂无记录" else "${rows.size} 条 · ${relTime(latest)}",Modifier.padding(top=5.dp),fontSize=Type.Caption,color=Muted,maxLines=1,overflow=TextOverflow.Ellipsis)
  }
  if(active)Text("正在查看 · 再点一次回到全部",Modifier.padding(top=10.dp),fontSize=Type.Micro,color=Ink)
 }
}

@Composable fun AgentTaskPage(vm:WorkbenchModel,back:()->Unit){
 var timed by remember{mutableStateOf(false)};var cron by remember{mutableStateOf(JSONObject())};var note by remember{mutableStateOf("")}
 LaunchedEffect(timed){if(timed)try{cron=vm.store.request("/personal/automations")}catch(e:Exception){note=e.message.orEmpty()}}
 Column(Modifier.fillMaxSize()){
  if(vm.taskDetailId.isBlank())Row(Modifier.fillMaxWidth().padding(horizontal=16.dp)){FilterChip(!timed,{timed=false},label={Text("任务")});Spacer(Modifier.width(8.dp));FilterChip(timed,{timed=true},label={Text("定时")})}
  Box(Modifier.weight(1f)){if(!timed||vm.taskDetailId.isNotBlank())TaskActivityPage(vm,back)else Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
   Text("Hermes 定时工作",fontSize=Type.AppTitle,fontWeight=FontWeight.SemiBold)
   if(note.isNotBlank())Text(note,color=AmberText)
   cron.array("jobs").forEach{r->AgentCard(r.optString("name")){Row(verticalAlignment=Alignment.CenterVertically){Icon(Icons.Outlined.Schedule,null,Modifier.size(18.dp),tint=Muted);Text(cronScheduleText(r),Modifier.padding(start=8.dp))};Text(if(r.optBoolean("enabled",true)&&!r.optBoolean("paused"))"已启用"else"已暂停",color=Muted);if(r.optString("next_run_at").isNotBlank())Text("下次 · ${personalDateText(r.optString("next_run_at"))}",fontSize=Type.Caption,color=Faint)}}
   if(cron.array("jobs").isEmpty())Text("暂未读取到定时任务",color=Muted)
  }}
  AgentSharedComposer(vm)
 }
}
@Composable fun AgentConnectionsPage(vm:WorkbenchModel,back:()->Unit){
 var data by remember{mutableStateOf(JSONObject())};var note by remember{mutableStateOf("")};var host by remember{mutableStateOf("")};var user by remember{mutableStateOf("")};var pass by remember{mutableStateOf("")};var garminUser by remember{mutableStateOf("")};var garminPass by remember{mutableStateOf("")};var region by remember{mutableStateOf("garmin.cn")};var googleHelp by remember{mutableStateOf(false)};val scope=rememberCoroutineScope()
 LaunchedEffect(Unit){runCatching{data=vm.store.request("/personal/connectors")}.onFailure{note=it.message.orEmpty()}}
 Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
  Row(verticalAlignment=Alignment.CenterVertically){RoundIcon(Icons.Outlined.ArrowBack,"返回",back);Text("数据连接",Modifier.padding(start=14.dp),fontSize=Type.AppTitle,fontWeight=FontWeight.SemiBold)}
  if(note.isNotBlank())Text(note,color=AmberText)
  data.array("sources").forEach{r->AgentCard(sourceName(r.optString("name"))){Text(connectionLabel(r.optString("status")));if(r.optString("error").isNotBlank())Text(r.optString("error"),fontSize=Type.Caption,color=Muted)}}
  AgentCard("搜狐工作邮箱 · IMAP"){
   OutlinedTextField(host,{host=it},label={Text("IMAP 服务器")},singleLine=true)
   OutlinedTextField(user,{user=it},label={Text("邮箱账号")},singleLine=true)
   OutlinedTextField(pass,{pass=it},label={Text("邮箱专用密码")},singleLine=true,visualTransformation=androidx.compose.ui.text.input.PasswordVisualTransformation())
   Button(onClick={scope.launch{try{vm.store.request("/personal/connectors/work_mail",JSONObject().put("host",host).put("username",user).put("password",pass));pass="";note="已保存，更新事项后核验连接"}catch(e:Exception){note=e.message.orEmpty()}}}){Text("连接工作邮箱")}
  }
  AgentCard("Google 授权"){Text("Gmail 与 Google 日历分别检查授权；日历连接正常时可先使用已有数据。",color=Muted);SettingsLink(Icons.Outlined.Login,"连接 Gmail","在 Mac mini 完成 Google 授权"){googleHelp=true}}
  AgentCard("佳明健康"){
   Row{listOf("garmin.cn" to "中国区","garmin.com" to "国际区").forEach{(domain,label)->FilterChip(region==domain,{region=domain},label={Text(label)},modifier=Modifier.padding(end=8.dp))}}
   OutlinedTextField(garminUser,{garminUser=it},label={Text("佳明账号")},singleLine=true,shape=RoundedCornerShape(16.dp))
   OutlinedTextField(garminPass,{garminPass=it},label={Text("密码")},singleLine=true,shape=RoundedCornerShape(16.dp),visualTransformation=androidx.compose.ui.text.input.PasswordVisualTransformation())
   FilledTonalButton(onClick={scope.launch{try{vm.store.request("/personal/connectors/garmin",JSONObject().put("domain",region).apply{if(garminUser.isNotBlank()){put("username",garminUser);put("password",garminPass)}});garminPass="";note="已保存到 mini，下一次同步核验。若要求验证码，将显示连接缺口。"}catch(e:Exception){note=e.message.orEmpty()}}},shape=Radii.Pill){Icon(Icons.Outlined.Link,null,Modifier.size(18.dp));Text("连接佳明",Modifier.padding(start=8.dp))}
  }
 }
 if(googleHelp)AlertDialog(onDismissRequest={googleHelp=false},title={Text("连接 Gmail")},text={Text("在 Mac mini 的终端运行 gws auth login，选择 Gmail 读取权限并完成 Google 登录。凭据保留在 mini；回到 Com! 点击“更新个人事项”核验。现有 Google 日历的独立授权继续保留。")},confirmButton={TextButton(onClick={googleHelp=false}){Text("知道了")}})
}

@Composable fun AgentDevicePage(vm:WorkbenchModel,back:()->Unit){
 val context=androidx.compose.ui.platform.LocalContext.current
 var enabled by remember{mutableStateOf(PhoneNodeService.enabled(context))};var caps by remember{mutableStateOf(JSONArray())};var note by remember{mutableStateOf("")};var tick by remember{mutableIntStateOf(0)}
 val permissions=androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()){tick++}
 val health=androidx.activity.compose.rememberLauncherForActivityResult(androidx.health.connect.client.PermissionController.createRequestPermissionResultContract()){tick++}
 LaunchedEffect(tick){try{caps=PhoneNodeTools(context).capabilities();if(enabled)PhoneNodeService.register(vm.store)}catch(e:Exception){note=e.message.orEmpty()}}
 LaunchedEffect(Unit){while(true){delay(5000);tick++}}
 Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
  Row(verticalAlignment=Alignment.CenterVertically){RoundIcon(Icons.Outlined.ArrowBack,"返回",back);Text("手机节点",Modifier.padding(start=14.dp),fontSize=Type.AppTitle,fontWeight=FontWeight.SemiBold)}
  Row{Text("允许 Hermes 调用已授权能力",Modifier.weight(1f));Switch(enabled,{enabled=it;PhoneNodeService.enable(context,it)})}
  Text(if(PhoneNodeService.online)"设备在线"else"设备离线 · 系统关闭服务后无法执行",color=Muted)
  if(note.isNotBlank())Text(note,color=AmberText)
  Button(onClick={permissions.launch(arrayOf(android.Manifest.permission.READ_CALENDAR,android.Manifest.permission.WRITE_CALENDAR,android.Manifest.permission.READ_CONTACTS,android.Manifest.permission.WRITE_CONTACTS,android.Manifest.permission.ACCESS_COARSE_LOCATION,android.Manifest.permission.CAMERA,if(android.os.Build.VERSION.SDK_INT>=33)android.Manifest.permission.READ_MEDIA_IMAGES else android.Manifest.permission.READ_EXTERNAL_STORAGE))}){Text("开放所需系统权限")}
  TextButton(onClick={context.startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))}){Text("应用使用权限")}
  TextButton(onClick={context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))}){Text("通知读取权限")}
  SettingsLink(Icons.Outlined.FavoriteBorder,"健康读取权限","按系统支持情况申请后台和历史读取"){runCatching{
   val client=androidx.health.connect.client.HealthConnectClient.getOrCreate(context)
   val required=mutableSetOf(androidx.health.connect.client.permission.HealthPermission.getReadPermission(androidx.health.connect.client.records.StepsRecord::class),androidx.health.connect.client.permission.HealthPermission.getReadPermission(androidx.health.connect.client.records.HeartRateRecord::class))
   if(client.features.getFeatureStatus(androidx.health.connect.client.HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_IN_BACKGROUND)==androidx.health.connect.client.HealthConnectFeatures.FEATURE_STATUS_AVAILABLE)required.add("android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND")
   if(client.features.getFeatureStatus(androidx.health.connect.client.HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_HISTORY)==androidx.health.connect.client.HealthConnectFeatures.FEATURE_STATUS_AVAILABLE)required.add("android.permission.health.READ_HEALTH_DATA_HISTORY")
   health.launch(required)
  }.onFailure{note="Health Connect 不可用或尚未安装"}}
  AgentCard("已注册的设备能力"){
   caps.objects().forEach{r->Row(Modifier.fillMaxWidth().padding(vertical=6.dp),verticalAlignment=Alignment.CenterVertically){Icon(if(r.optBoolean("permission"))Icons.Outlined.CheckCircleOutline else Icons.Outlined.Lock,null,Modifier.size(18.dp),tint=Muted);Text(deviceToolLabel(r.optString("tool")),Modifier.weight(1f).padding(start=10.dp),fontSize=Type.BodySm);Text(if(!r.optBoolean("available",true))"系统不可用"else if(r.optBoolean("permission"))"已授权"else"未授权",fontSize=Type.Caption,color=Faint)}}
  }
  Text("每次调用保留回执。闹钟和应用启动受系统前台限制，以手机实际界面为准。",fontSize=Type.Caption,color=Faint)
 }
}

private fun sourceName(value:String)=when(value){"gmail"->"Gmail";"work_mail"->"搜狐工作邮箱";"github"->"GitHub 项目";"apple_calendar"->"苹果日历";"google_calendar"->"Google 日历";"accounting"->"原记账账本";"garmin"->"佳明健康";"com_task"->"Com 任务";"phone_health"->"手机 Health Connect";"phone_calendar"->"手机日历";else->value}
private fun matterFactsText(f:JSONObject):String{
 if(f.has("expense_minor"))return "${f.optString("month")} · 支出 ¥${"%.2f".format(f.optLong("expense_minor")/100.0)} · 收入 ¥${"%.2f".format(f.optLong("income_minor")/100.0)} · ${f.optInt("count")} 笔"
 if(f.has("start")){
  fun date(key:String):String {return f.optJSONObject(key)?.let{it.optString("dateTime",it.optString("date"))}?:f.optString(key)}
  return "${personalDateText(date("start"))} — ${personalDateText(date("end"))}"
 }
 if(f.has("snippet"))return f.optString("from")+"\n"+f.optString("snippet")
 if(f.has("repository"))return f.optString("repository")
 if(f.has("measurements")){val m=f.optJSONObject("measurements")?:JSONObject();return "${f.optString("date")} · 步数 ${if(m.isNull("steps"))"缺失"else m.optString("steps")} · 静息心率 ${if(m.isNull("resting_heart_rate"))"缺失"else m.optString("resting_heart_rate")}"}
 if(f.has("steps"))return "步数 ${if(f.isNull("steps"))"缺失" else f.optString("steps")} · ${f.optString("start")} 至 ${f.optString("end")}\n${f.optString("missing_reason","")}"
 if(f.has("status"))return statusLabel(f.optString("status"))
 return f.optString("from")+"\n"+f.optString("date")
}

private fun personalDateText(value:String):String=runCatching{java.time.OffsetDateTime.parse(value).atZoneSameInstant(java.time.ZoneId.of("Asia/Shanghai")).format(java.time.format.DateTimeFormatter.ofPattern("M月d日 HH:mm"))}.getOrElse{value}
private fun cronScheduleText(row:JSONObject):String{
 val expr=row.optJSONObject("schedule")?.optString("expr")?:row.optString("schedule_display",row.optString("schedule"))
 return when(expr){"*/15 * * * *"->"每 15 分钟";"*/30 * * * *"->"每 30 分钟";"0 9 * * *"->"每天 09:00 · 北京时间";else->row.optJSONObject("schedule")?.optString("display",expr)?:expr}
}
private fun deviceToolLabel(tool:String)=mapOf("calendar.list" to "读取手机日历","calendar.create" to "新建手机日程","calendar.update" to "调整手机日程","contacts.search" to "查找联系人","contacts.create" to "新建联系人","apps.list" to "查看应用","apps.usage" to "应用使用时长","apps.launch" to "打开应用","notifications.list" to "读取通知","notifications.dismiss" to "清除指定通知","health.summary" to "步数与心率","alarm.set" to "设置闹钟","alarm.show" to "查看闹钟","location.last" to "最近位置","media.list" to "查看媒体","device.status" to "设备与电量","device.vibrate" to "振动反馈","device.volume" to "媒体音量","device.torch" to "手电筒")[tool]?:tool

@Composable fun AgentActionPage(vm:WorkbenchModel,back:()->Unit){
 var data by remember{mutableStateOf(JSONObject())};var note by remember{mutableStateOf("")};var busy by remember{mutableStateOf(false)};val scope=rememberCoroutineScope()
 suspend fun refresh(){data=vm.store.request("/personal/actions")}
 LaunchedEffect(Unit){runCatching{refresh()}.onFailure{note=it.message.orEmpty()}}
 Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),verticalArrangement=Arrangement.spacedBy(14.dp)){
  Row(verticalAlignment=Alignment.CenterVertically){RoundIcon(Icons.Outlined.ArrowBack,"返回",back);Text("安排变更",Modifier.padding(start=14.dp),fontSize=Type.AppTitle,fontWeight=FontWeight.SemiBold)}
  Text("个人日程与提醒的每次变更都保留回执。撤销时会重新核对原对象。",fontSize=Type.Caption,color=Muted)
  if(note.isNotBlank())Text(note,color=AmberText)
  data.array("items").forEach{row->
   val args=row.optJSONObject("args")?:JSONObject();val result=row.optJSONObject("result")?:JSONObject()
   AgentCard(args.optString("summary",args.optString("text",args.optJSONObject("event")?.optString("title")?:"个人安排变更"))){
    Text(row.optString("reason"),color=Muted,fontSize=Type.BodySm)
    Text("${relTime(row.optDouble("created_at"))} · ${if(row.optBoolean("undone"))"已撤销并回读" else if(result.optBoolean("verified"))"已回读核验"else"结果待核实"}",fontSize=Type.Caption,color=Faint)
    if(result.optBoolean("verified")&&!row.optBoolean("undone")&&(row.optString("tool")!="remind"||args.optString("action")=="add"))FilledTonalButton(onClick={scope.launch{busy=true;try{val r=vm.store.request("/personal/actions/${row.optString("id")}/undo",JSONObject().put("request_id",UUID.randomUUID().toString()));note=if(r.optBoolean("verified"))"撤销完成，已核对原对象"else"撤销结果待核实";refresh()}catch(e:Exception){note=e.message.orEmpty()}finally{busy=false}}},enabled=!busy,shape=Radii.Pill){Icon(Icons.Outlined.Undo,null,Modifier.size(18.dp));Text("撤销",Modifier.padding(start=8.dp))}
   }
  }
  if(data.array("items").isEmpty())Text("还没有个人安排变更",color=Muted)
 }
}
