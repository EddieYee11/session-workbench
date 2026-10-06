package work.eddie.sessions

import android.Manifest
import android.os.Bundle
import android.content.*
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon as AndroidIcon
import android.webkit.*
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.activity.compose.BackHandler
import androidx.activity.viewModels
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.*
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.*
import androidx.compose.ui.viewinterop.AndroidView
import io.noties.markwon.Markwon
import io.noties.markwon.ext.tables.TablePlugin
import kotlinx.coroutines.*
import org.json.*
import java.text.SimpleDateFormat
import java.util.*

class MainActivity:ComponentActivity(){
 private val vm:WorkbenchModel by viewModels()
 var quick by mutableStateOf("")
 var workLaunch by mutableIntStateOf(0)
 override fun onCreate(savedInstanceState:Bundle?){super.onCreate(savedInstanceState)
   enableEdgeToEdge()
   handleIntent(intent)
   if(android.os.Build.VERSION.SDK_INT>=33)requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS),10)
   val shortcuts=listOf(
    ShortcutInfo.Builder(this,"hermes-voice").setShortLabel("和 Hermes 说一句").setIcon(AndroidIcon.createWithResource(this,R.drawable.ic_launcher)).setIntent(Intent(this,QuickVoiceActivity::class.java).setAction(Intent.ACTION_ASSIST)).build(),
    ShortcutInfo.Builder(this,"voice").setShortLabel("语音记账").setIcon(AndroidIcon.createWithResource(this,R.drawable.ic_launcher)).setIntent(Intent(this,ExpenseVoiceActivity::class.java).setAction(Intent.ACTION_VIEW)).build()
   )+listOf("claude","codex").map{a->ShortcutInfo.Builder(this,a).setShortLabel("新建 ${a.replaceFirstChar{it.uppercase()}}").setIcon(AndroidIcon.createWithResource(this,R.drawable.ic_launcher)).setIntent(Intent(this,MainActivity::class.java).setAction(Intent.ACTION_VIEW).putExtra("agent",a)).build()}
   Thread { getSystemService(ShortcutManager::class.java).dynamicShortcuts=shortcuts }.start()
   androidx.work.WorkManager.getInstance(this).enqueueUniquePeriodicWork("session-updates",androidx.work.ExistingPeriodicWorkPolicy.KEEP,androidx.work.PeriodicWorkRequestBuilder<StatusWorker>(15,java.util.concurrent.TimeUnit.MINUTES).setConstraints(androidx.work.Constraints.Builder().setRequiredNetworkType(androidx.work.NetworkType.CONNECTED).build()).build())
   if(SignalConfig.enabled(this))SignalSync.schedule(this)
   setContent{MaterialTheme(colorScheme=Palette,typography=ComTypography,shapes=ComShapes){Workbench(vm,quick,workLaunch){quick=""}}}
 }
 override fun onStart(){super.onStart();PhoneNodeService.appVisible=true;if(PhoneNodeService.enabled(this))PhoneNodeService.enable(this,true);vm.active=true;if(vm.store.token.isNotEmpty()){vm.refreshPersonalNow();vm.refreshHermesNow();vm.refreshWorkProposalsNow();vm.refreshGoalProposalsNow()};if(SignalConfig.enabled(this)&&SignalConfig.accessGranted(this))SignalSync.schedule(this)}
 override fun onPause(){vm.store.flushPending();super.onPause()}
 override fun onStop(){PhoneNodeService.appVisible=false;vm.store.flushPending();vm.finishHermesVoice(false);vm.active=false;vm.liveFresh=false;vm.allRowsFresh=false;vm.personalFresh=false;vm.hermesFresh=false;vm.signalsFresh=false;vm.signalsHealthFresh=false;vm.taskLedgerFresh=false;vm.workProposalsFresh=false;vm.goalProposalsFresh=false;vm.reminderFresh=false;super.onStop()}
 override fun onNewIntent(intent:Intent){super.onNewIntent(intent);setIntent(intent);handleIntent(intent)}
 private fun handleIntent(intent:Intent){
  if(intent.action==Intent.ACTION_SEND&&intent.type?.startsWith("text/")==true){
   val text=intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString().orEmpty()
   if(text.isNotBlank()){
    vm.receiveShare(text,referrer?.host.orEmpty())
    intent.removeExtra(Intent.EXTRA_TEXT)
   }
  }
  val sid=intent.getStringExtra("sid").orEmpty()
  quick=intent.getStringExtra("agent").orEmpty()
  if(sid.isNotBlank()){vm.openId(sid);workLaunch++} else if(quick.isNotBlank()){vm.close();workLaunch++}
  if(intent.getBooleanExtra("signal_activity",false)){vm.showSignalsActivity=true;vm.externalHermesRoute++}
  // Close the old scene before observing delivery; an already-completed worker may open immediately.
  intent.getStringExtra("voice_work")?.let{vm.followVoiceDelivery(it)}
 }
}

fun agentDisplayName(agent:String):String=when(agent){"pi"->"Pi";"claude"->"Claude";"hermes"->"Hermes";else->"Codex"}

@Composable fun AgentBadge(agent:String){Surface(shape=Radii.Pill,color=if(agent=="pi")PiSoft else AccentSoft,shadowElevation=1.dp){Row(Modifier.padding(horizontal=10.dp,vertical=5.dp),verticalAlignment=Alignment.CenterVertically){Box(Modifier.size(6.dp).background(if(agent=="pi")PiGreen else Ember,CircleShape));Text(agentDisplayName(agent),Modifier.padding(start=6.dp),fontSize=Type.Caption,fontWeight=FontWeight.SemiBold,color=if(agent=="pi")PiGreen else EmberDeep,letterSpacing=.4.sp)}}}
@Composable fun Choice(label:String,options:List<String>,select:(String)->Unit){var show by remember{mutableStateOf(false)};Box{TextButton(onClick={show=true},contentPadding=PaddingValues(horizontal=8.dp)){Text(label,fontSize=Type.Caption,maxLines=1);Icon(Icons.Outlined.ExpandMore,null,Modifier.size(15.dp))};DropdownMenu(show,{show=false}){options.forEach{o->DropdownMenuItem(text={Text(o,fontSize=Type.BodySm)},onClick={select(o);show=false})}}}}
fun dayLabel(ts:Double):String {val date=Date((ts*1000).toLong());val fmt=SimpleDateFormat("yyyy-MM-dd",Locale.CHINA);return when(fmt.format(date)){fmt.format(Date())->"今天";fmt.format(Date(System.currentTimeMillis()-86400000))->"昨天";else->SimpleDateFormat("M月d日",Locale.CHINA).format(date)}}
private val whitespace=Regex("\\s+")
fun highlight(text:String,q:String):AnnotatedString=buildAnnotatedString{append(text);if(q.isNotBlank())q.trim().split(whitespace).forEach{term->var start=0;while(start<text.length){val i=text.indexOf(term,start,true);if(i<0)break;addStyle(SpanStyle(background=Color(0xFFFFE6A5),color=Ink),i,i+term.length);start=i+term.length}}}

@Composable fun Approval(vm:WorkbenchModel,a:JSONObject){
 val id=a.optString("id")
 // 已拿到回执：收成一行灰色小结，确认操作生效，也不再遮挡视野。
 val outcome=vm.approvalOutcomes[id]
 if(outcome!=null){ResolvedApproval(vm,id,outcome);return}
 val busy=vm.approvalBusyId==id
 val haptics=rememberComHaptics()
 val p=a.optJSONObject("params")?:JSONObject();val questions=p.array("questions");val answers=remember(id){mutableStateMapOf<String,String>()}
 SpringIn(Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=6.dp)){
  Surface(shape=RoundedCornerShape(Radii.Xl),color=Card,border=BorderStroke(1.dp,AmberLine),shadowElevation=Elev.Raised){
   Column(Modifier.padding(Spacing.Xl)){
    Row(verticalAlignment=Alignment.CenterVertically){
     Box(Modifier.size(36.dp).background(AmberBg,CircleShape),contentAlignment=Alignment.Center){Icon(Icons.Outlined.NotificationImportant,null,Modifier.size(18.dp),tint=AmberText)}
     Column(Modifier.padding(start=12.dp)){
      Text("需要你回应",fontWeight=FontWeight.SemiBold,fontSize=Type.Body,color=Ink)
      Text("来自 Mac mini 的执行请求",fontSize=Type.Caption,color=Muted)
     }
    }
    Surface(Modifier.padding(top=12.dp).fillMaxWidth(),shape=RoundedCornerShape(Radii.M),color=ToolSurface,border=BorderStroke(1.dp,Line)){Text(p.optString("command",p.optString("reason","请确认以下操作")),Modifier.padding(12.dp),fontSize=Type.BodySm,lineHeight=19.sp,color=Ink,maxLines=6)}
    if(questions.isNotEmpty()){
     questions.forEach{q->Text(q.optString("question"),fontSize=Type.BodySm);q.array("options").forEach{o->FilterChip(answers[q.optString("id")]==o.optString("label"),{answers[q.optString("id")]=o.optString("label")},label={Text(o.optString("label"))})};OutlinedTextField(answers[q.optString("id")]?:"",{answers[q.optString("id")]=it},label={Text("回答")},modifier=Modifier.fillMaxWidth().padding(top=6.dp))}
     Button(onClick={haptics(HapticCue.Commit);vm.respondApproval(id,JSONObject().put("answers",JSONObject(answers.toMap())))},enabled=!busy){Text(if(busy)"提交中…" else "提交回答")}
    }else Row(Modifier.padding(top=12.dp),horizontalArrangement=Arrangement.spacedBy(8.dp)){
     val (okPress,okMotion)=rememberPress()
     Button(onClick={haptics(HapticCue.Commit);vm.respondApproval(id,JSONObject().put("decision","accept"))},enabled=!busy,modifier=Modifier.weight(1f).height(46.dp).then(okMotion),shape=Radii.Pill,interactionSource=okPress,colors=ButtonDefaults.buttonColors(containerColor=Ember)){Text(if(busy)"提交中…" else "允许本次",fontWeight=FontWeight.SemiBold)}
     val (noPress,noMotion)=rememberPress()
     OutlinedButton(onClick={haptics(HapticCue.Reject);vm.respondApproval(id,JSONObject().put("decision","decline"))},enabled=!busy,modifier=Modifier.weight(1f).height(46.dp).then(noMotion),shape=Radii.Pill,interactionSource=noPress){Text("拒绝",color=Muted)}
    }
   }
  }
 }
}

/** 已回执的回应请求：一行灰色小结，替代原来一直占屏的大卡片。 */
@Composable private fun ResolvedApproval(vm:WorkbenchModel,id:String,outcome:String){
 val undelivered=outcome=="未送达"
 val label=when(outcome){"已允许"->"已允许";"已拒绝"->"已拒绝";"已结束"->"这条请求已结束";else->"已回应"}
 Row(Modifier.fillMaxWidth().padding(horizontal=22.dp,vertical=6.dp),verticalAlignment=Alignment.CenterVertically){
  Icon(if(undelivered)Icons.Outlined.ErrorOutline else Icons.Outlined.CheckCircle,null,Modifier.size(15.dp),tint=if(undelivered)AmberText else Faint)
  Text(if(undelivered)"回应未送达" else label,Modifier.padding(start=8.dp),fontSize=Type.Caption,color=if(undelivered)AmberText else Faint)
  vm.approvalErrors[id]?.takeIf{undelivered&&it.isNotBlank()}?.let{Text(it,Modifier.padding(start=8.dp).weight(1f,fill=false),fontSize=Type.Caption,color=Muted,maxLines=1,overflow=TextOverflow.Ellipsis)}
  // 只有真的没送达才给重试；请求早已结束的情况重试没有意义。
  if(undelivered)TextButton(onClick={vm.approvalOutcomes.remove(id);vm.approvalErrors.remove(id)},contentPadding=PaddingValues(horizontal=8.dp)){Text("重试",fontSize=Type.Caption)}
 }
}

@Composable fun SessionMenu(vm:WorkbenchModel,s:JSONObject,dismiss:()->Unit){
 var title by remember{mutableStateOf(s.optString("display_title"))};var confirmEnd by remember{mutableStateOf(false)}
 AlertDialog(onDismissRequest=dismiss,title={Text("会话详情")},text={Column{
  Text("${s.optString("agent")} · ${s.optString("cwd")}",fontSize=Type.Caption,color=Muted)
  SelectionContainer{Text(s.optString("id"),fontSize=Type.Micro,color=Muted)}
  OutlinedTextField(title,{title=it},label={Text("会话标题")},modifier=Modifier.padding(top=12.dp))
  TextButton(onClick={vm.label(s.getString("id"),JSONObject().put("pinned",if(s.optInt("pinned")==1)0 else 1));dismiss()}){Text(if(s.optInt("pinned")==1)"取消置顶" else "置顶会话")}
  TextButton(onClick={vm.label(s.getString("id"),JSONObject().put("archived",if(s.optInt("archived")==1)0 else 1));dismiss()}){Text(if(s.optInt("archived")==1)"移出归档" else "归档（保留原始记录）")}
  if(s.optBoolean("managed"))TextButton(onClick={confirmEnd=true}){Text("结束远端会话",color=Danger)}
 }},confirmButton={TextButton(onClick={vm.label(s.getString("id"),JSONObject().put("title",title));dismiss()}){Text("保存标题")}},dismissButton={TextButton(onClick=dismiss){Text("关闭")}})
 if(confirmEnd)AlertDialog(onDismissRequest={confirmEnd=false},title={Text("结束远端会话？")},text={Text("这会关闭正在运行的终端进程。历史仍然保留。")},confirmButton={TextButton(onClick={vm.end();dismiss()}){Text("结束")}},dismissButton={TextButton(onClick={confirmEnd=false}){Text("取消")}})
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun NewSession(vm:WorkbenchModel,quick:String,dismiss:()->Unit){
 var agent by remember{mutableStateOf(quick.takeIf{it in listOf("claude","codex")}?:vm.store.prefs.getString("lastAgent","claude").takeIf{it in listOf("claude","codex")}?:"claude")};var cwd by remember{mutableStateOf(vm.store.prefs.getString("lastCwd","/Users/eddiegao/AI_Work_System")?:"")}
 var prompt by rememberSaveable{mutableStateOf("")};var model by remember(agent){mutableStateOf(vm.selection(agent).model)};var effort by remember(agent){mutableStateOf(vm.selection(agent).effort)};var advanced by remember{mutableStateOf(false)};var browse by remember{mutableStateOf(false)};var modelPicker by remember{mutableStateOf(false)}
 val motion=LocalMessageSendMotion.current
 val composerSource=remember{Any()}
 val create:()->Unit={
  val text=prompt.trim();val rid=UUID.randomUUID().toString()
  vm.chooseModel(agent,"",model,effort)
  if(text.isNotBlank())motion?.begin(rid,text,sourceKey=composerSource)
  val accepted=vm.create(agent,cwd,text,model,effort,rid)
  if(accepted==null)motion?.cancel()else{motion?.retarget(rid,accepted);dismiss()}
 }
 // Material3's modal owns its window insets. The content consumes them once.
 ModalBottomSheet(onDismissRequest=dismiss,containerColor=Paper,sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true)){Column(Modifier.padding(horizontal=24.dp).verticalScroll(rememberScrollState()).testTag("advanced-session-sheet")){
 StaggerIn(0){Column{Text("开启新的工作",fontSize=Type.SheetTitle,fontWeight=FontWeight.SemiBold,letterSpacing=(-.3).sp);Text("运行在 Mac mini · 完整操作权限",Modifier.padding(top=6.dp,bottom=18.dp),fontSize=Type.BodySm,color=Muted)}}
 val (createPress,createMotion)=rememberPress(.97f)
 StaggerIn(1){Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){listOf("pi","claude","codex").forEach{a->FilterChip(agent==a,{agent=a},label={Text(agentDisplayName(a),fontSize=17.sp)},modifier=Modifier.height(48.dp))}}}
 Text("工作目录",Modifier.padding(top=16.dp),fontSize=Type.Caption,color=Muted)
 TextButton(onClick={browse=true}){Icon(Icons.Outlined.FolderOpen,null);Text(cwd,Modifier.padding(start=8.dp),fontSize=Type.BodySm,maxLines=2)}
 AdvancedSessionComposer(prompt,{prompt=it},motion,!vm.busy&&vm.connected,create,composerSource)
 TextButton(onClick={advanced=!advanced}){Text(if(advanced)"收起高级设置" else "高级设置")}
 if(advanced){
  TextButton(onClick={modelPicker=true;vm.loadModels(agent)}){Icon(Icons.Outlined.AutoAwesome,null);Text("${vm.catalogs[agent]?.firstOrNull{it.id==model}?.label?:model.ifBlank{"跟随 Mac 默认"}} · ${effort.ifBlank{"默认推理"}}",Modifier.padding(start=8.dp),maxLines=1)}
  Text("完整操作权限",Modifier.padding(horizontal=8.dp,vertical=6.dp).testTag("work-operation-permission"),fontSize=Type.Caption,color=Muted)
 }
 StaggerIn(2){Button(onClick=create,enabled=!vm.busy&&vm.connected,modifier=Modifier.fillMaxWidth().padding(top=12.dp,bottom=28.dp).height(54.dp).then(createMotion),shape=Radii.Pill,interactionSource=createPress,colors=ButtonDefaults.buttonColors(containerColor=Ember)){Text(if(prompt.isBlank())"打开空会话" else "开始会话",fontSize=Type.Body,fontWeight=FontWeight.SemiBold)}}
 }}
 if(browse)DirectoryPicker(vm,cwd,{cwd=it;browse=false}){browse=false}
 if(modelPicker)ModelPickerSheet(agent,vm.catalogs[agent].orEmpty(),model,effort,vm.catalogLoading[agent]==true,vm.catalogErrors[agent],{modelPicker=false},{chosen,level->model=chosen;effort=level;modelPicker=false},{vm.loadModels(agent,true)})
}

/** The exact measured text layout is also the source of the main-window send overlay. */
@Composable internal fun AdvancedSessionComposer(text:String,change:(String)->Unit,motion:MessageSendMotionState?,enabled:Boolean,send:()->Unit,sourceKey:Any?=null){
 var editing by remember{mutableStateOf(TextFieldValue(text,TextRange(text.length)))}
 LaunchedEffect(text){if(editing.text!=text)editing=TextFieldValue(text,TextRange(text.length))}
 val style=TextStyle(fontSize=Type.Body,lineHeight=22.sp,color=Ink)
 Surface(Modifier.fillMaxWidth().messageSendComposerBounds(motion,background=true,backgroundColor=UserBubble,sourceKey=sourceKey),shape=RoundedCornerShape(Radii.Xl),color=UserBubble,border=BorderStroke(1.dp,Line)){
  Column(Modifier.padding(16.dp)){
   BasicTextField(editing,{editing=it;change(it.text)},Modifier.fillMaxWidth().heightIn(min=80.dp,max=200.dp).testTag("advanced-session-composer").messageSendComposerBounds(motion,sourceKey=sourceKey),
    textStyle=style,keyboardOptions=KeyboardOptions(imeAction=ImeAction.Send),keyboardActions=KeyboardActions(onSend={if(enabled&&text.isNotBlank())send()}),
    onTextLayout={motion?.updateComposerLayout(it,style,backgroundColor=UserBubble,cornerRadius=Radii.Xl,sourceKey=sourceKey)},cursorBrush=SolidColor(Ink),
    decorationBox={inner->Box{if(text.isBlank())Text("想做什么？也可以先打开空会话。",style=style.copy(color=Faint));inner()}})
   if(text.isNotBlank())Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.End){
    IconButton(onClick={val start=editing.selection.min;val next=editing.text.replaceRange(start,editing.selection.max,"\n");editing=TextFieldValue(next,TextRange(start+1));change(next)},modifier=Modifier.size(32.dp)){Icon(Icons.Outlined.KeyboardReturn,"插入换行",Modifier.size(19.dp),tint=Muted)}
   }
  }
 }
}
@Composable fun DirectoryPicker(vm:WorkbenchModel,initial:String,choose:(String)->Unit,dismiss:()->Unit){
 var path by remember{mutableStateOf(initial)};var data by remember{mutableStateOf(JSONObject())};var error by remember{mutableStateOf("")}
 LaunchedEffect(path){try{data=vm.store.request("/directories?path=${vm.enc(path)}")}catch(e:Exception){error=e.message?:"无法读取目录"}}
 AlertDialog(onDismissRequest=dismiss,title={Text("选择工作目录")},text={Column{Text(path,fontSize=Type.Caption,color=Muted);if(error.isNotBlank())Text(error);LazyColumn(Modifier.height(300.dp)){
 if(!data.isNull("parent")&&data.optString("parent").isNotBlank())item{TextButton(onClick={path=data.getString("parent")}){Text("↑ 上一级")}}
 val recent=data.optJSONArray("recent");if(recent!=null)items(recent.length()){i->TextButton(onClick={choose(recent.getString(i))}){Text("最近 · "+recent.getString(i).shortPath())}}
 val dirs=data.optJSONArray("directories");if(dirs!=null)items(dirs.length()){i->TextButton(onClick={path=dirs.getString(i)}){Text(dirs.getString(i).shortPath())}}
 }}},confirmButton={TextButton(onClick={choose(path)}){Text("使用此目录")}},dismissButton={TextButton(onClick=dismiss){Text("取消")}})
}
@Composable fun SettingsSheet(vm:WorkbenchModel,navigate:(String)->Unit={},dismiss:()->Unit){
 val context=androidx.compose.ui.platform.LocalContext.current
 var base by remember{mutableStateOf(vm.store.base.ifBlank{"https://pi.eddiegao.work:8443/sessions"})};var code by remember{mutableStateOf("")};var notify by remember{mutableStateOf(vm.store.prefs.getBoolean("notifications",true))}
 Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal=20.dp).padding(bottom=28.dp),verticalArrangement=Arrangement.spacedBy(14.dp)){
  Row(Modifier.fillMaxWidth().padding(bottom=6.dp),verticalAlignment=Alignment.CenterVertically){
   Column(Modifier.weight(1f)){Text("设置",fontSize=Type.AppTitle,fontWeight=FontWeight.SemiBold);Text("Com! · Hermes 个人助手",fontSize=Type.Caption,color=Muted)}
   RoundIcon(Icons.Outlined.Close,"关闭设置",dismiss)
  }
  SettingsSection(ReferenceIcons.Sliders,"个人助手","Hermes · DeepSeek V4 Flash"){
   SettingsLink(Icons.Outlined.Link,"数据连接","邮箱、日历、账本与健康"){navigate("connectors")}
   SettingsLink(Icons.Outlined.Smartphone,"手机节点","权限、在线状态与工具能力"){navigate("devices")}
   SettingsLink(Icons.Outlined.History,"安排变更与撤销","查看个人安排的操作回执"){navigate("actions")}
   SettingsLink(Icons.Outlined.AdminPanelSettings,"权限与执行","当前用户 Full Access · 操作保留回执"){navigate("diagnostics")}
  }
  SettingsSection(Icons.Outlined.Schedule,"主动行为","北京时间 09:00 晨报"){
   HeartbeatSettings(vm)
  }
  SettingsSection(Icons.Outlined.MicNone,"语音与快捷入口"){
   Text("小窗、语音记账和主聊天由 Hermes 连续处理。记账结果以原账本回读为准，重复请求沿用原回执。",fontSize=Type.Caption,color=Muted)
   SettingsLink(Icons.Outlined.AccountBalanceWallet,"打开语音记账"){context.startActivity(Intent(context,ExpenseVoiceActivity::class.java))}
   SettingsLink(Icons.Outlined.Assistant,"系统默认助手"){context.startActivity(Intent(android.provider.Settings.ACTION_VOICE_INPUT_SETTINGS))}
  }
  SettingsSection(Icons.Outlined.Wifi,"服务与配对",if(vm.connected)"Mac mini 已连接" else "连接暂不可用"){
   OutlinedTextField(base,{base=it},label={Text("HTTPS 服务地址")},modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(16.dp),singleLine=true)
   OutlinedTextField(code,{code=it},label={Text("一次性配对码")},modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(16.dp),singleLine=true)
   FilledTonalButton(onClick={vm.run{vm.store.base=base;val r=vm.store.request("/pair",JSONObject().put("code",code),false);vm.store.token=r.getString("token");vm.refresh();vm.refreshPersonal();vm.refreshHermes();SignalSync.immediate(context);dismiss()}},shape=Radii.Pill){Icon(Icons.Outlined.Link,null,Modifier.size(18.dp));Text("配对并连接",Modifier.padding(start=8.dp))}
  }
  SettingsSection(Icons.Outlined.TextFields,"显示与通知"){
   Text("聊天字号 ${vm.font.toInt()}",fontSize=Type.BodySm)
   Slider(vm.font,{vm.font=it;vm.store.prefs.edit().putFloat("font",it).apply()},valueRange=14f..22f,steps=7)
   Row(verticalAlignment=Alignment.CenterVertically){Column(Modifier.weight(1f)){Text("任务状态通知",fontSize=Type.BodySm);Text("完成、失败与等待回应",fontSize=Type.Caption,color=Muted)};Switch(notify,{notify=it;vm.store.prefs.edit().putBoolean("notifications",it).apply()})}
   Text("历史索引 ${vm.index.optInt("done")}/${vm.index.optInt("total")} · 暂无法读取 ${vm.index.optInt("unreadable")} 份",fontSize=Type.Caption,color=Muted)
  }
  SettingsSection(Icons.Outlined.NotificationsNone,"通知观察") {SignalSettings(context)}
  Text("离线可查看已缓存内容。凭据由 Android Keystore 加密保存。",Modifier.padding(horizontal=4.dp),fontSize=Type.Caption,color=Faint)
 }
}

@Composable fun Terminal(vm:WorkbenchModel,sid:String){
 var web by remember{mutableStateOf<WebView?>(null)}
 DisposableEffect(sid){onDispose{web?.apply{loadUrl("about:blank");removeJavascriptInterface("Native");destroy()};web=null}}
 Column(Modifier.fillMaxSize().background(Color(0xFF151B24))){
  AndroidView(modifier=Modifier.weight(1f).fillMaxWidth(),factory={context->WebView(context).apply{
   WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG);web=this;setBackgroundColor(android.graphics.Color.rgb(21,27,36));settings.javaScriptEnabled=true;settings.domStorageEnabled=false;settings.allowFileAccess=true;settings.allowContentAccess=false
   addJavascriptInterface(object{
    @JavascriptInterface fun configuration():String=JSONObject().put("base",vm.store.base).put("token",vm.store.token).put("sid",sid).toString()
    @JavascriptInterface fun history():String=runBlocking{vm.store.request("/sessions/${vm.enc(sid)}/terminal-history").toString()}
   },"Native")
   webViewClient=object:WebViewClient(){override fun shouldOverrideUrlLoading(view:WebView,request:WebResourceRequest)=true}
   loadUrl("file:///android_asset/terminal.html")
  }})
  fun key(value:String){web?.evaluateJavascript("window.key(${JSONObject.quote(value)})",null)}
  Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceEvenly){
   listOf("↑" to "UP","↓" to "DOWN","←" to "LEFT","→" to "RIGHT","Enter" to "\r").forEach{(label,value)->TextButton(onClick={key(value)},modifier=Modifier.heightIn(min=48.dp)){Text(label,color=Color.White,fontSize=Type.Body)}}
  }
  Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),horizontalArrangement=Arrangement.spacedBy(1.dp)){
   listOf("回看" to "HISTORY","Esc" to "\u001b","Tab" to "\t","Ctrl" to "CTRL","模型" to "MODEL","粘贴" to "PASTE","复制" to "COPY","−" to "SMALL","＋" to "LARGE").forEach{(label,value)->TextButton(onClick={
    if(value=="PASTE"){
     val clip=vm.store.context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
     val text=clip.primaryClip?.takeIf{it.itemCount>0}?.getItemAt(0)?.coerceToText(vm.store.context)?.toString()?:""
     web?.evaluateJavascript("window.pasteText(${JSONObject.quote(text)})",null)
    }else if(value=="COPY")web?.evaluateJavascript("window.selectedText()",{raw->
     val text=runCatching{JSONArray("["+raw+"]").getString(0)}.getOrDefault("")
     if(text.isNotBlank())(vm.store.context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager).setPrimaryClip(ClipData.newPlainText("终端",text))
    }) else key(value)
   },enabled=value!="MODEL"||vm.live.optString("status") !in listOf("running","waiting"),contentPadding=PaddingValues(horizontal=10.dp),modifier=Modifier.heightIn(min=48.dp)){Text(label,color=Color.White,fontSize=Type.BodySm)}}
  }
 }
}
