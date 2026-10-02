package work.eddie.sessions

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
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
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.TextRange
import java.util.UUID
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
 "sent"->"已发送"
 "read"->"已读"
 "thinking"->"正在思考"
 "executing"->"正在执行"
 "responding","streaming"->"正在回复"
 "completed"->"回复结束"
 "failed"->"处理失败"
 "unknown"->"结果待核实 · 不会自动重发"
 "approval_required"->"待授权"
 else->""
}

fun hermesPhaseStatus(phase:String):String=when(phase){
 "received"->"已接收"
 "sent"->"已发送"
 "read"->"已读"
 "thinking"->"正在思考"
 "executing","tool"->"正在执行"
 "responding","replying","streaming"->"正在回复"
 "completed"->"回复结束"
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
@Composable fun HermesChat(vm:WorkbenchModel,menu:()->Unit,showMenu:Boolean,openTasks:()->Unit){
 DisposableEffect(Unit){onDispose{vm.finishHermesVoice(false)}}
 val haptics=rememberComHaptics()
 var lastReactionSequence by remember{mutableIntStateOf(vm.hermesReactionSequence)}
 LaunchedEffect(vm.hermesReactionSequence){
  if(vm.hermesReactionSequence>lastReactionSequence&&vm.active&&vm.hermesVisible)haptics(HapticCue.Reaction)
  lastReactionSequence=vm.hermesReactionSequence
 }
 val sharedMotion=LocalMessageSendMotion.current
 val motion=sharedMotion?:rememberMessageSendMotionState(vm.active&&vm.hermesVisible)
 val data=vm.hermes
 val outgoing=vm.outgoingMessages.filter{it.scope=="personal-main"}
 val messages=remember(data,outgoing){mergeOutgoingMessages(data.array("messages"),outgoing)}
 val runs=data.array("runs")
 val backgroundTasks=buildLedgerTasks(vm.taskLedger.array("items"),messages)
 val activeTasks=backgroundTasks.count{it.status=="active"}
 val list=rememberLazyListState()
 MessageViewportAnchor(list,"hermes",vm.hermesVisible,motion)
 var positionedAtLatest by remember{mutableStateOf(false)}
 MessageSendListScroll(motion,list,messages.indexOfFirst{messageMotionId(it)==motion.messageId}.takeIf{it>=0}?.plus(1))
 var activity by remember{mutableStateOf(false)}
 LaunchedEffect(vm.showSignalsActivity){if(vm.showSignalsActivity){activity=true;vm.showSignalsActivity=false}}
 LaunchedEffect(activity){if(activity){vm.refreshSignalsNow();vm.refreshWorkProposalsNow()}}
 val hasConversation=data.optString("conversation_id").isNotBlank()
 val canSend=vm.hermesFresh&&!vm.hermesSending&&vm.store.token.isNotEmpty()
 val proposals=vm.workProposals.array("items").filter{it.optString("status")=="proposed"}
 val needsAttention=runs.any{it.optString("status") in setOf("waiting","unknown")}
 LaunchedEffect(messages.size,messages.lastOrNull()?.optString("id"),messages.lastOrNull()?.optString("text"),messages.lastOrNull()?.optString("phase")){
  if(motion.messageId!=null)return@LaunchedEffect
  val lastVisible=list.layoutInfo.visibleItemsInfo.lastOrNull()?.index?:0
  if(messages.size>4&&(!positionedAtLatest||lastVisible>=messages.size-1)){
   list.scrollToItem(messages.size+1)
   positionedAtLatest=true
  }
 }
 LaunchedEffect(proposals.map{it.optString("id")}){
  if(motion.messageId!=null)return@LaunchedEffect
  val lastVisible=list.layoutInfo.visibleItemsInfo.lastOrNull()?.index?:0
  if(proposals.isNotEmpty()&&lastVisible>=messages.size-1)list.animateScrollToItem(messages.size+1)
 }
 Box(Modifier.fillMaxSize()){
 Column(Modifier.fillMaxSize().background(Paper),horizontalAlignment=Alignment.CenterHorizontally){
  BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()){
   val inset=if(maxWidth>=700.dp)32.dp else 15.dp
   val wideHero=maxWidth>=700.dp
   LazyColumn(state=list,modifier=Modifier.fillMaxSize().testTag("hermes-message-list"),contentPadding=PaddingValues(start=inset,end=inset,top=88.dp,bottom=18.dp),horizontalAlignment=Alignment.CenterHorizontally){
    item(key="intro"){
     Column(Modifier.widthIn(max=790.dp).fillMaxWidth()){
      if(messages.isEmpty())HermesHero(wideHero){vm.updateHermesDraft(it)}
      if(vm.hermesError.isNotBlank()&&!vm.hermesFresh)Text("连接提示：${vm.hermesError}",Modifier.padding(top=8.dp),fontSize=12.sp,color=AmberText)
      if(hasConversation&&!vm.hermesFresh)Text("以下是上次保存的对话。联网并同步后才能继续发送。",fontSize=12.sp,color=AmberText)
     }
    }
    items(messages,key={messageMotionId(it).ifBlank{it.toString()}}){message->
     MessageSendRow(motion,messageMotionId(message),Modifier.widthIn(max=790.dp).fillMaxWidth(),trailingSpacing=22.dp){Column{
      MessageSwipeActions(message,enabled=!message.optBoolean("local"),onReply={vm.hermesReference=messageReference(it,"reply","Hermes","personal-main")},onForward={vm.hermesReference=messageReference(it,"forward","Hermes","personal-main")}){HermesMessage(message,motion)}
      if(message.optString("role")=="user")Box(Modifier.messageSendMetadata(motion,messageMotionId(message))){HermesProgressCard(message,vm.hermesFresh)}
     }}
    }
    item(key="tail"){
     Column(Modifier.widthIn(max=790.dp).fillMaxWidth()){
      if(messages.isEmpty()&&hasConversation)Text("想从什么事开始？日历和账本会按真实来源回答。",fontSize=14.sp,color=Muted)
      proposals.forEach{proposal->WorkProposalCard(vm,proposal)}
      if(vm.workProposalNote.isNotBlank())Text(vm.workProposalNote,Modifier.padding(top=8.dp),fontSize=12.sp,color=Muted)
     }
    }
   }
   // Messages scroll under a translucent header, instead of losing 128dp to an opaque block.
   Box(Modifier.fillMaxWidth().height(98.dp).align(Alignment.TopCenter)
    .background(Brush.verticalGradient(0f to Paper.copy(alpha=.98f),.40f to Paper.copy(alpha=.86f),.76f to Paper.copy(alpha=.38f),1f to Color.Transparent))
    .testTag("hermes-fading-header")){
    Row(Modifier.fillMaxWidth().height(76.dp).padding(horizontal=16.dp),verticalAlignment=Alignment.CenterVertically){
     if(showMenu)Surface(onClick=menu,modifier=Modifier.size(44.dp),shape=CircleShape,color=Card.copy(alpha=.8f)){
      ComIcon(R.drawable.com_icon_menu_v1,"打开导航",Modifier.padding(11.dp))
     }else Text("Com!",fontSize=17.sp,fontWeight=FontWeight.Bold,color=Ink)
     Row(Modifier.weight(1f).clickable{openTasks()},horizontalArrangement=Arrangement.Center,verticalAlignment=Alignment.CenterVertically){
      val current=messages.lastOrNull{it.optString("role")=="user"}
      val phase=current?.optString("phase").orEmpty()
      val status=current?.optString("status").orEmpty()
      val visual=when{
       vm.hermesVoicePhase=="recording"->"listening"
       !vm.hermesFresh&&!vm.hermesLoading->"offline"
       vm.hermesSending||(!vm.hermesFresh&&vm.hermesLoading)||vm.hermesVoicePhase=="transcribing"->"thinking"
       status in setOf("failed","unknown")->"error"
       status in setOf("queued","sending","running")->when(phase){"responding","replying","streaming"->"responding";"executing","tool"->"working";else->"thinking"}
       else->"idle"
      }
      HermesCompanion(visual,Modifier.size(58.dp),compact=true,animationActive=vm.active&&vm.hermesVisible)
      Column(Modifier.padding(start=3.dp),verticalArrangement=Arrangement.spacedBy(2.dp)){
       Text("Hermes",fontSize=16.sp,fontWeight=FontWeight.SemiBold,color=Ink)
       val label=when{
        vm.hermesVoicePhase=="recording"->"正在倾听"
        vm.hermesFresh&&vm.taskLedgerFresh&&activeTasks>0->"$activeTasks 项后台任务"
        vm.hermesFresh->hermesActivityStatus(runs,messages)
        vm.hermesLoading->"连接中"
        else->"离线记录"
       }
       AnimatedContent(label,transitionSpec={fadeIn(tween(150)) togetherWith fadeOut(tween(90))},label="Hermes实际阶段"){
        Text(it,fontSize=10.sp,color=if(vm.hermesFresh)Muted else AmberText,maxLines=1)
       }
      }
     }
     Box{
      Surface(onClick=openTasks,modifier=Modifier.size(44.dp),shape=CircleShape,color=Card.copy(alpha=.8f)){
       ComIcon(R.drawable.com_icon_activity_v1,"查看 Hermes 活动",Modifier.padding(11.dp))
      }
      if(needsAttention)Box(Modifier.align(Alignment.TopEnd).size(9.dp).background(Ember,CircleShape).border(2.dp,Paper,CircleShape))
     }
    }
   }
  }
  vm.hermesReference?.let{MessageReferencePreview(it){vm.hermesReference=null}}
  HermesComposer(vm,canSend,motion)
 }
 if(sharedMotion==null)MessageSendMotionOverlay(motion,Modifier.fillMaxSize())
 }
 if(activity)ModalBottomSheet(onDismissRequest={activity=false},containerColor=Paper){
  Column(Modifier.fillMaxWidth().heightIn(max=560.dp).verticalScroll(rememberScrollState()).padding(horizontal=22.dp).padding(bottom=28.dp)){
   Row(verticalAlignment=Alignment.CenterVertically){
    ComIcon(R.drawable.com_icon_activity_v1,null,Modifier.size(24.dp))
    Text("Hermes 活动",Modifier.padding(start=5.dp),fontSize=22.sp,fontWeight=FontWeight.SemiBold,color=Ink)
   }
   Text(if(vm.hermesFresh)"当前状态：${hermesActivityStatus(runs,messages)}${if(vm.hermesStreaming)" · 实时同步"else" · 快照同步"}"else"离线记录，状态待同步",Modifier.padding(top=4.dp,bottom=8.dp),fontSize=12.sp,color=Muted)
   TaskLedgerSection(vm,runs,messages)
   WorkProposalSection(vm)
   SignalActivitySection(vm)
  }
 }
}

@Composable private fun HermesMessage(message:JSONObject,motion:MessageSendMotionState){
 val motionId=messageMotionId(message)
 val style=TextStyle(fontSize=16.sp,lineHeight=24.sp,color=Ink)
 val user=message.optString("role")=="user"
 val status=message.optString("status")
 val phase=hermesPhaseStatus(message.optString("phase"))
 val text=message.optString("text")
 val color=if(user)HermesUserBubble else HermesAssistantBubble
 Column(Modifier.fillMaxWidth(),horizontalAlignment=if(user)Alignment.End else Alignment.Start){
  Surface(Modifier.messageSendMotionTarget(motion,motionId).messageSendTargetBounds(motion,motionId).testTag(if(user)"hermes-user-bubble" else "hermes-assistant-bubble").widthIn(max=680.dp).fillMaxWidth(if(user).88f else .96f),shape=RoundedCornerShape(28.dp),color=color){
   Column(Modifier.padding(horizontal=15.dp,vertical=12.dp)){
    message.optJSONObject("reference")?.let{reference->Text("${if(reference.optString("mode")=="forward")"引用"else"回复"} · ${reference.optString("author")}\n${reference.optString("text")}",Modifier.padding(bottom=8.dp),fontSize=12.sp,lineHeight=17.sp,color=Muted,maxLines=3,overflow=TextOverflow.Ellipsis)}
    SelectionContainer{Text(text.ifBlank{phase},Modifier.messageSendTargetBounds(motion,motionId,text=true),style=style,onTextLayout={motion.updateTargetLayout(motionId,it,style,color,if(message.optJSONObject("reference")!=null)MessageSendContentKind.RichText else MessageSendContentKind.Text)})}
   }
  }
  val emoji=if(user)message.optJSONObject("reaction")?.optString("emoji").orEmpty() else ""
  AnimatedVisibility(emoji.isNotBlank(),enter=fadeIn(tween(160))+scaleIn(tween(200, easing=Motion.TravelEasing),initialScale=.92f),exit=fadeOut(tween(90))+scaleOut(tween(90),targetScale=.96f)){
   Surface(Modifier.padding(end=12.dp,top=4.dp).semantics{contentDescription="Hermes 对这条消息的表情：$emoji"},shape=Radii.Pill,color=Card,border=BorderStroke(1.dp,Line)){
    Text(emoji,Modifier.padding(horizontal=10.dp,vertical=3.dp),fontSize=19.sp)
   }
  }
 val activeTool=if(message.isNull("active_tool"))"" else message.optString("active_tool").take(48)
 val state=phase.ifBlank{hermesMessageStatus(status)}.let{if(phase=="正在执行"&&activeTool.isNotBlank())"$it · $activeTool" else it}
  val time=messageTime(message.opt("created_at"))
  val compactState=if(user&&status in setOf("queued","sending","running","unknown","failed","approval_required"))"" else state
  if(compactState.isNotBlank()||time.isNotBlank())Text(listOf(time,compactState).filter{it.isNotBlank()}.joinToString(" · "),Modifier.messageSendMetadata(motion,motionId).padding(start=8.dp,end=8.dp,top=4.dp),fontSize=11.sp,color=if(status in listOf("failed","unknown"))Danger else Faint)
  if(status in listOf("failed","unknown")&&message.optString("error").isNotBlank())Text(message.optString("error"),Modifier.messageSendMetadata(motion,motionId).padding(horizontal=8.dp,vertical=2.dp),fontSize=11.sp,color=Danger)
 }
}

@Composable private fun HermesProgressCard(message:JSONObject,fresh:Boolean){
 val status=message.optString("status")
 val visible=status in setOf("queued","sending","running","waiting","approval_required","failed","unknown")
 AnimatedVisibility(visible,enter=fadeIn(tween(160)),exit=fadeOut(tween(90))){
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
}

@Composable private fun HermesProposalCard(proposal:JSONObject,openActivity:()->Unit){
 val statusText=when(proposal.optString("status")){
  "proposed"->"待授权"
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

@Composable private fun HermesComposer(vm:WorkbenchModel,enabled:Boolean,motion:MessageSendMotionState){
 val style=TextStyle(fontSize=15.sp,lineHeight=22.sp,color=Ink)
 val send:()->Unit={if(enabled&&vm.hermesDraft.isNotBlank()){val rid=vm.hermesPending.optString("request_id").ifBlank{UUID.randomUUID().toString()};motion.begin(rid,vm.hermesDraft.trim());if(vm.sendHermes(rid)==null)motion.cancel()}}
 LaunchedEffect(vm.hermesVoiceAutoSend){
  val text=vm.hermesVoiceAutoSend?:return@LaunchedEffect
  // External draft -> TextFieldValue -> text layout, then use the same submit path.
  withFrameNanos{}
  withFrameNanos{}
  if(vm.consumeHermesVoiceSend(text))send()
 }
 val value=vm.hermesDraft
 var editing by remember{mutableStateOf(TextFieldValue(value,TextRange(value.length)))}
 LaunchedEffect(value){if(editing.text!=value)editing=TextFieldValue(value,TextRange(value.length))}
 val newline:()->Unit={val start=editing.selection.min;val next=editing.text.replaceRange(start,editing.selection.max,"\n");editing=TextFieldValue(next,TextRange(start+1));vm.updateHermesDraft(next)}
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
   BasicTextField(editing,{editing=it;vm.updateHermesDraft(it.text)},Modifier.weight(1f).heightIn(min=42.dp,max=120.dp).padding(horizontal=9.dp,vertical=10.dp).testTag("hermes-composer").messageSendComposerBounds(motion,background=true,backgroundColor=UserBubble).messageSendComposerBounds(motion),readOnly=voice!="idle",textStyle=style,keyboardOptions=KeyboardOptions(imeAction=ImeAction.Send),keyboardActions=KeyboardActions(onSend={if(voice=="idle")send()}),onTextLayout={motion.updateComposerLayout(it,style)},cursorBrush=SolidColor(Ink),decorationBox={inner->Box{if(value.isBlank())Text(if(voice=="recording")"录音中 ${vm.hermesVoiceSeconds} 秒…"else"消息",style=style.copy(color=Faint));inner()}})
   if(value.isNotBlank()&&voice=="idle")IconButton(onClick=newline,modifier=Modifier.size(36.dp)){Icon(Icons.Outlined.KeyboardReturn,"插入换行",Modifier.size(19.dp),tint=Muted)}
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
   }else IconButton(onClick={haptics(HapticCue.Commit);send()},enabled=enabled,modifier=Modifier.size(43.dp).background(if(enabled)Ink else ChipBg,CircleShape)){
    if(vm.hermesSending)CircularProgressIndicator(Modifier.size(20.dp),strokeWidth=2.dp,color=Muted)
    else ComIcon(R.drawable.com_icon_send_v1,"发送给 Hermes",Modifier.size(22.dp),alpha=if(enabled)1f else .45f,tint=if(enabled)Color.White else Muted)
   }
  }
 }
 if(!enabled)Text(if(vm.store.token.isBlank())"配对后可与 Hermes 对话"else if(vm.hermesSending)"正在发送"else"Hermes 未连接，草稿会保留",Modifier.fillMaxWidth().padding(start=24.dp,bottom=7.dp),fontSize=11.sp,color=AmberText)
}
