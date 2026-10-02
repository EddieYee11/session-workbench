package work.eddie.sessions

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONObject
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

fun hermesMessageStatus(status:String):String=when(status){
 "queued"->"已排队"
 "sending"->"正在交给 Hermes"
 "running"->"正在处理"
 "waiting"->"等待你回应"
 "received"->"已接收"
 "read"->"已读"
 "thinking"->"正在思考"
 "executing"->"正在执行"
 "responding","streaming"->"正在回复"
 "completed"->"已完成"
 "failed"->"处理失败"
 "unknown"->"结果待核实 · 不会自动重发"
 "approval_required"->"已自动继续"
 else->""
}

fun hermesPhaseStatus(phase:String):String=when(phase){
 "received"->"已接收"
 "read"->"已读"
 "thinking"->"正在思考"
 "executing","tool"->"正在执行"
 "responding","replying","streaming"->"正在回复"
 "completed"->"已完成"
 "failed"->"处理失败"
 "unknown"->"结果待核实 · 不会自动重发"
 else->""
}

private fun messageTime(value:Any?):String=runCatching{
 fun epoch(number:Double)=Instant.ofEpochMilli(if(number>=100_000_000_000.0)number.toLong() else (number*1000).toLong())
 val instant=when(value){
  is Number->epoch(value.toDouble())
  is String->runCatching{OffsetDateTime.parse(value).toInstant()}.getOrElse{epoch(value.toDouble())}
  else->return ""
 }
 instant.atZone(ZoneId.of("Asia/Shanghai")).format(DateTimeFormatter.ofPattern("M月d日 HH:mm",Locale.CHINA))
}.getOrDefault("")

private fun hermesActivityStatus(runs:List<JSONObject>,messages:List<JSONObject>):String{
 val activeMessage=messages.lastOrNull{it.optString("phase") in setOf("received","read","thinking","executing","tool","responding","replying","streaming")}
 if(activeMessage!=null&&activeMessage.optString("status") !in setOf("completed","failed","unknown"))return hermesPhaseStatus(activeMessage.optString("phase"))
 val active=runs.lastOrNull{it.optString("status") in listOf("running","sending","queued","waiting","approval_required","unknown")}
 return when(active?.optString("status")){
  "running","sending"->"正在处理"
  "queued"->"任务已排队"
  "waiting","approval_required"->"等待你回应"
  "unknown"->"状态待核实"
  else->"空闲"
 }
}

private fun hermesToolLabel(name:String):String=when{
 name.endsWith("personal_overview")->"正在读取日历与账本概览"
 name.endsWith("recent_work_sessions")->"正在核对 Pi / Codex 工作会话"
 name.endsWith("propose_work")->"正在准备工作建议"
 name.endsWith("work_proposal_status")->"正在核对工作建议"
 name.isNotBlank()->"正在使用 ${name.take(46)}"
 else->"Hermes 正在处理这条消息"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun HermesChat(vm:WorkbenchModel,menu:()->Unit,showMenu:Boolean){
 DisposableEffect(Unit){onDispose{vm.finishHermesVoice(false)}}
 val haptics=rememberComHaptics()
 val data=vm.hermes
 val messages=data.array("messages")
 val runs=data.array("runs")
 val list=rememberLazyListState()
 var activity by remember{mutableStateOf(false)}
 LaunchedEffect(vm.showSignalsActivity){if(vm.showSignalsActivity){activity=true;vm.showSignalsActivity=false}}
 LaunchedEffect(activity){if(activity){vm.refreshSignalsNow();vm.refreshWorkProposalsNow()}}
 val hasConversation=data.optString("conversation_id").isNotBlank()
 val canSend=vm.hermesFresh&&!vm.hermesSending&&vm.store.token.isNotEmpty()
 val proposals=vm.workProposals.array("items").filter{it.optString("status") !in setOf("rejected","expired")}.take(2)
 val needsAttention=runs.any{it.optString("status") in setOf("waiting","unknown")}
 LaunchedEffect(messages.size,messages.lastOrNull()?.optString("id"),messages.lastOrNull()?.optString("text"),messages.lastOrNull()?.optString("phase")){
  val lastVisible=list.layoutInfo.visibleItemsInfo.lastOrNull()?.index?:0
  if(messages.size>4&&lastVisible>=messages.size-1)list.scrollToItem(messages.size+1)
 }
 LaunchedEffect(vm.hermesSendNote){
  if(vm.hermesSendNote.startsWith("Hermes 已接收"))list.scrollToItem(messages.size+1)
 }
 Column(Modifier.fillMaxSize().background(Paper),horizontalAlignment=Alignment.CenterHorizontally){
  Box(Modifier.fillMaxWidth().height(128.dp).padding(horizontal=16.dp)){
   if(showMenu)Surface(onClick=menu,modifier=Modifier.align(Alignment.CenterStart).size(44.dp),shape=CircleShape,color=Card,border=BorderStroke(1.dp,Line)){
    ComIcon(R.drawable.com_icon_menu_v1,"打开导航",Modifier.padding(11.dp))
   }else Text("Com!",Modifier.align(Alignment.CenterStart),fontSize=17.sp,fontWeight=FontWeight.Bold,color=Ink)
   Column(Modifier.align(Alignment.Center).clickable{activity=true},horizontalAlignment=Alignment.CenterHorizontally){
    Image(painterResource(R.drawable.hermes_companion_v1),"Hermes",Modifier.size(76.dp),contentScale=ContentScale.Fit)
    Text("Hermes",fontSize=16.sp,fontWeight=FontWeight.SemiBold,color=Ink)
    Text(if(vm.hermesFresh)hermesActivityStatus(runs,messages) else if(vm.hermesLoading)"连接中" else "离线记录",fontSize=10.sp,color=if(vm.hermesFresh)Muted else AmberText,maxLines=1)
   }
   Box(Modifier.align(Alignment.CenterEnd)){
    Surface(onClick={activity=true},modifier=Modifier.size(44.dp),shape=CircleShape,color=Card,border=BorderStroke(1.dp,Line)){
     ComIcon(R.drawable.com_icon_activity_v1,"查看 Hermes 活动",Modifier.padding(11.dp))
    }
    if(needsAttention)Box(Modifier.align(Alignment.TopEnd).size(9.dp).background(Ember,CircleShape).border(2.dp,Paper,CircleShape))
   }
  }
  BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()){
   val inset=if(maxWidth>=700.dp)32.dp else 15.dp
   val wideHero=maxWidth>=700.dp
   LazyColumn(state=list,modifier=Modifier.fillMaxSize(),contentPadding=PaddingValues(start=inset,end=inset,top=15.dp,bottom=18.dp),verticalArrangement=Arrangement.spacedBy(22.dp),horizontalAlignment=Alignment.CenterHorizontally){
    item(key="intro"){
     Column(Modifier.widthIn(max=790.dp).fillMaxWidth()){
      if(messages.isEmpty())HermesHero(wideHero){vm.updateHermesDraft(it)}
      if(vm.hermesError.isNotBlank()&&!vm.hermesFresh)Text("连接提示：${vm.hermesError}",Modifier.padding(top=8.dp),fontSize=12.sp,color=AmberText)
      if(hasConversation&&!vm.hermesFresh)Text("以下是上次保存的对话。联网并同步后才能继续发送。",fontSize=12.sp,color=AmberText)
     }
    }
    items(messages,key={it.optString("id").ifBlank{it.toString()}}){message->
     Column(Modifier.widthIn(max=790.dp).fillMaxWidth()){
      HermesMessage(message)
      if(message.optString("role")=="user")HermesProgressCard(message,vm.hermesFresh)
     }
    }
    item(key="tail"){
     Column(Modifier.widthIn(max=790.dp).fillMaxWidth()){
      if(messages.isEmpty()&&hasConversation)Text("想从什么事开始？日历和账本会按真实来源回答。",fontSize=14.sp,color=Muted)
      if(vm.workProposalsFresh)proposals.take(2).forEach{proposal->
       HermesProposalCard(proposal){activity=true}
      }
     }
    }
   }
  }
  HermesComposer(vm,canSend)
 }
 if(activity)ModalBottomSheet(onDismissRequest={activity=false},containerColor=Paper){
  Column(Modifier.fillMaxWidth().heightIn(max=560.dp).verticalScroll(rememberScrollState()).padding(horizontal=22.dp).padding(bottom=28.dp)){
   Row(verticalAlignment=Alignment.CenterVertically){
    ComIcon(R.drawable.com_icon_activity_v1,null,Modifier.size(24.dp))
    Text("Hermes 活动",Modifier.padding(start=5.dp),fontSize=22.sp,fontWeight=FontWeight.SemiBold,color=Ink)
   }
   Text(if(vm.hermesFresh)"当前状态：${hermesActivityStatus(runs,messages)}${if(vm.hermesStreaming)" · 实时同步"else" · 快照同步"}"else"离线记录，状态待同步",Modifier.padding(top=4.dp,bottom=16.dp),fontSize=12.sp,color=Muted)
   if(runs.isEmpty())Text("暂无可查看的执行记录",fontSize=13.sp,color=Muted)
   else runs.takeLast(12).asReversed().forEach{run->
    val source=messages.firstOrNull{it.optString("id")==run.optString("message_id")}
    val title=run.optString("title").ifBlank{run.optString("summary").ifBlank{source?.optString("text")?.take(80).orEmpty().ifBlank{"执行记录"}}}
    Surface(Modifier.fillMaxWidth().padding(bottom=8.dp),shape=RoundedCornerShape(Radii.L),color=Card,border=BorderStroke(1.dp,Line)){
     Column(Modifier.padding(14.dp)){
      Text(title,fontSize=14.sp,fontWeight=FontWeight.Medium,color=Ink,maxLines=2,overflow=TextOverflow.Ellipsis)
      Text(listOf(run.optString("agent"),hermesMessageStatus(run.optString("status")),messageTime(run.opt("updated_at"))).filter{it.isNotBlank()}.joinToString(" · "),Modifier.padding(top=4.dp),fontSize=11.sp,color=Muted)
     }
    }
   }
   WorkProposalSection(vm)
   SignalActivitySection(vm)
  }
 }
}

@Composable private fun HermesMessage(message:JSONObject){
 val user=message.optString("role")=="user"
 val status=message.optString("status")
 val phase=hermesPhaseStatus(message.optString("phase"))
 val text=message.optString("text")
 val color=UserBubble
 Column(Modifier.fillMaxWidth(),horizontalAlignment=if(user)Alignment.End else Alignment.Start){
  Surface(Modifier.widthIn(max=680.dp).fillMaxWidth(if(user).88f else .96f),shape=RoundedCornerShape(28.dp),color=color){
   Column(Modifier.padding(horizontal=15.dp,vertical=12.dp)){
    SelectionContainer{Text(text.ifBlank{phase},fontSize=16.sp,lineHeight=24.sp,color=Ink)}
   }
  }
 val activeTool=if(message.isNull("active_tool"))"" else message.optString("active_tool").take(48)
 val state=phase.ifBlank{hermesMessageStatus(status)}.let{if(phase=="正在执行"&&activeTool.isNotBlank())"$it · $activeTool" else it}
  val time=messageTime(message.opt("created_at"))
  val compactState=if(user&&status in setOf("queued","sending","running","unknown","failed","approval_required"))"" else state
  if(compactState.isNotBlank()||time.isNotBlank())Text(listOf(time,compactState).filter{it.isNotBlank()}.joinToString(" · "),Modifier.padding(start=8.dp,end=8.dp,top=4.dp),fontSize=11.sp,color=if(status in listOf("failed","unknown"))Danger else Faint)
  if(status in listOf("failed","unknown")&&message.optString("error").isNotBlank())Text(message.optString("error"),Modifier.padding(horizontal=8.dp,vertical=2.dp),fontSize=11.sp,color=Danger)
 }
}

@Composable private fun HermesProgressCard(message:JSONObject,fresh:Boolean){
 val status=message.optString("status")
 if(status !in setOf("queued","sending","running","waiting","approval_required","failed","unknown"))return
 val phase=message.optString("phase")
 val label=hermesPhaseStatus(phase).ifBlank{hermesMessageStatus(status)}
 val tool=if(message.isNull("active_tool"))"" else message.optString("active_tool")
 val terminal=status in setOf("failed","unknown")
 val body=when{
  status=="unknown"->"结果待核实，Com! 不会自动重发这条消息。"
  status=="failed"->message.optString("error").ifBlank{"这次处理失败，请查看活动记录。"}
  status=="waiting"->"需要你在活动中查看下一步。"
  !fresh->"上次同步时：${if(tool.isNotBlank())hermesToolLabel(tool) else label}"
  tool.isNotBlank()->hermesToolLabel(tool)
  phase=="responding"->"正在把回复写进这段对话"
  else->"Hermes 正在处理这条消息"
 }
 Surface(Modifier.padding(start=8.dp,top=9.dp).widthIn(max=590.dp).fillMaxWidth(.94f),shape=RoundedCornerShape(18.dp),color=if(terminal)AmberBg else ToolSurface,border=BorderStroke(1.dp,if(terminal)AmberLine else Line)){
  Row(Modifier.padding(horizontal=13.dp,vertical=11.dp),verticalAlignment=Alignment.CenterVertically){
   if(!terminal&&fresh&&status in setOf("queued","sending","running"))ThinkingDots(Ember)
   else ComIcon(R.drawable.com_icon_activity_v1,null,Modifier.size(24.dp))
   Column(Modifier.padding(start=10.dp)){
    Text(if(fresh)label else "离线记录",fontSize=12.sp,fontWeight=FontWeight.SemiBold,color=if(terminal)AmberText else Ink)
    Text(body,Modifier.padding(top=2.dp),fontSize=11.sp,lineHeight=16.sp,color=if(terminal)AmberText else Muted)
   }
  }
 }
}

@Composable private fun HermesProposalCard(proposal:JSONObject,openActivity:()->Unit){
 val statusText=when(proposal.optString("status")){
  "proposed"->"已自动接单"
  "dispatching"->"正在派发"
  "accepted"->"已启动"
  else->"动态"
 }
 Surface(onClick=openActivity,modifier=Modifier.fillMaxWidth().padding(top=12.dp),shape=RoundedCornerShape(Radii.Xl),color=Card,border=BorderStroke(1.dp,Line)){
  Row(Modifier.padding(14.dp),verticalAlignment=Alignment.CenterVertically){
   ComIcon(R.drawable.com_icon_work_v1,null,Modifier.size(24.dp))
   Column(Modifier.weight(1f).padding(horizontal=8.dp)){
    Text("$statusText · ${proposal.optString("agent").uppercase(Locale.ROOT)} 工作动态",fontSize=11.sp,fontWeight=FontWeight.SemiBold,color=Muted)
    Text(proposal.optString("title").ifBlank{"工作动态"},Modifier.padding(top=3.dp),fontSize=14.sp,fontWeight=FontWeight.Medium,color=Ink,maxLines=2,overflow=TextOverflow.Ellipsis)
   }
   ComIcon(R.drawable.com_icon_chevron_v1,"查看详情",Modifier.size(24.dp))
  }
 }
}

@Composable private fun HermesComposer(vm:WorkbenchModel,enabled:Boolean){
 val value=vm.hermesDraft
 val pending=vm.hermesPending.optString("text")
 val voice=vm.hermesVoicePhase
 val context=LocalContext.current
 val haptics=rememberComHaptics()
 val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){granted->
  if(granted)vm.beginHermesVoice()else vm.hermesVoicePermissionDenied()
 }
 if(pending.isNotBlank()&&!vm.hermesSending)Row(Modifier.fillMaxWidth().padding(horizontal=20.dp,vertical=3.dp),verticalAlignment=Alignment.CenterVertically){
  Text("上一条发送结果待核实：${pending.take(48)}",Modifier.weight(1f),fontSize=11.sp,color=AmberText,maxLines=2,overflow=TextOverflow.Ellipsis)
  TextButton(onClick={vm.stopHermesRetry()}){Text("停止重试",fontSize=11.sp)}
 }
 if(vm.hermesSendNote.isNotBlank())Text(vm.hermesSendNote,Modifier.fillMaxWidth().padding(horizontal=24.dp,vertical=2.dp),fontSize=11.sp,color=AmberText)
 if(vm.hermesVoiceNote.isNotBlank())Text(vm.hermesVoiceNote,Modifier.fillMaxWidth().padding(horizontal=24.dp,vertical=2.dp),fontSize=11.sp,color=AmberText)
 if(vm.hermesVoiceSaved.isNotBlank()&&voice=="idle")Row(Modifier.fillMaxWidth().padding(horizontal=20.dp),verticalAlignment=Alignment.CenterVertically){
  Text("保留了一段录音",Modifier.weight(1f),fontSize=11.sp,color=AmberText)
  TextButton(onClick={vm.transcribeHermesVoice()}){Text("重试转写",fontSize=11.sp)}
  TextButton(onClick={vm.discardHermesVoice()}){Text("删除",fontSize=11.sp)}
 }
 Surface(Modifier.widthIn(max=810.dp).fillMaxWidth().padding(horizontal=16.dp,vertical=8.dp),shape=RoundedCornerShape(32.dp),color=UserBubble){
  Row(Modifier.padding(horizontal=8.dp,vertical=5.dp),verticalAlignment=Alignment.Bottom){
   IconButton(onClick={vm.showSignalsActivity=true},modifier=Modifier.size(44.dp)){Icon(Icons.Outlined.Add,"查看活动与工作建议",Modifier.size(25.dp),tint=Ink)}
   BasicTextField(value,vm::updateHermesDraft,Modifier.weight(1f).heightIn(min=42.dp,max=120.dp).padding(horizontal=9.dp,vertical=10.dp),readOnly=voice!="idle",textStyle=TextStyle(fontSize=15.sp,lineHeight=22.sp,color=Ink),cursorBrush=SolidColor(Ink),decorationBox={inner->Box{if(value.isBlank())Text(if(voice=="recording")"录音中 ${vm.hermesVoiceSeconds} 秒…"else"消息",fontSize=15.sp,color=Faint);inner()}})
   if(value.isBlank()||voice!="idle"){
    val voiceEnabled=voice=="recording"||voice=="idle"&&pending.isBlank()&&vm.hermesVoiceSaved.isBlank()&&vm.store.token.isNotBlank()
    IconButton(onClick={
     if(voice=="recording")vm.finishHermesVoice()
     else if(context.checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)vm.beginHermesVoice()
     else permission.launch(Manifest.permission.RECORD_AUDIO)
    },enabled=voiceEnabled,modifier=Modifier.size(43.dp).background(if(voice=="recording")Danger else Color.Transparent,CircleShape)){
     if(voice=="transcribing")CircularProgressIndicator(Modifier.size(20.dp),strokeWidth=2.dp,color=Muted)
     else if(voice=="recording")Icon(Icons.Outlined.Stop,"结束录音并发送给 Hermes",Modifier.size(22.dp),tint=Color.White)
     else ComIcon(R.drawable.com_icon_mic_v1,"录音发送给 Hermes",Modifier.size(24.dp),tint=Muted)
    }
   }else IconButton(onClick={haptics(HapticCue.Commit);vm.sendHermes()},enabled=enabled,modifier=Modifier.size(43.dp).background(if(enabled)Ink else ChipBg,CircleShape)){
    if(vm.hermesSending)CircularProgressIndicator(Modifier.size(20.dp),strokeWidth=2.dp,color=Muted)
    else ComIcon(R.drawable.com_icon_send_v1,"发送给 Hermes",Modifier.size(22.dp),alpha=if(enabled)1f else .45f,tint=if(enabled)Color.White else Muted)
   }
  }
 }
 if(!enabled)Text(if(vm.store.token.isBlank())"配对后可与 Hermes 对话"else if(vm.hermesSending)"正在发送"else"Hermes 未连接，草稿会保留",Modifier.fillMaxWidth().padding(start=24.dp,bottom=7.dp),fontSize=11.sp,color=AmberText)
}
