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
    ShortcutInfo.Builder(this,"hermes-voice").setShortLabel("和 Pi 说一句").setIcon(AndroidIcon.createWithResource(this,R.drawable.ic_launcher)).setIntent(Intent(this,QuickVoiceActivity::class.java).setAction(Intent.ACTION_ASSIST)).build(),
    ShortcutInfo.Builder(this,"voice").setShortLabel("语音记账").setIcon(AndroidIcon.createWithResource(this,R.drawable.ic_launcher)).setIntent(Intent(this,ExpenseVoiceActivity::class.java).setAction(Intent.ACTION_VIEW)).build()
   )+listOf("pi","codex").map{a->ShortcutInfo.Builder(this,a).setShortLabel("新建 ${a.replaceFirstChar{it.uppercase()}}").setIcon(AndroidIcon.createWithResource(this,R.drawable.ic_launcher)).setIntent(Intent(this,MainActivity::class.java).setAction(Intent.ACTION_VIEW).putExtra("agent",a)).build()}
   Thread { getSystemService(ShortcutManager::class.java).dynamicShortcuts=shortcuts }.start()
   androidx.work.WorkManager.getInstance(this).enqueueUniquePeriodicWork("session-updates",androidx.work.ExistingPeriodicWorkPolicy.KEEP,androidx.work.PeriodicWorkRequestBuilder<StatusWorker>(15,java.util.concurrent.TimeUnit.MINUTES).setConstraints(androidx.work.Constraints.Builder().setRequiredNetworkType(androidx.work.NetworkType.CONNECTED).build()).build())
   if(SignalConfig.enabled(this))SignalSync.schedule(this)
   setContent{MaterialTheme(colorScheme=Palette){Workbench(vm,quick,workLaunch){quick=""}}}
 }
 override fun onStart(){super.onStart();vm.active=true;if(vm.store.token.isNotEmpty()){vm.refreshPersonalNow();vm.refreshHermesNow()};if(SignalConfig.enabled(this)&&SignalConfig.accessGranted(this))SignalSync.schedule(this)}
 override fun onStop(){vm.finishHermesVoice(false);vm.active=false;vm.liveFresh=false;vm.allRowsFresh=false;vm.personalFresh=false;vm.hermesFresh=false;vm.signalsFresh=false;vm.signalsHealthFresh=false;vm.taskLedgerFresh=false;super.onStop()}
 override fun onNewIntent(intent:Intent){super.onNewIntent(intent);setIntent(intent);handleIntent(intent)}
 private fun handleIntent(intent:Intent){
  val sid=intent.getStringExtra("sid").orEmpty()
  quick=intent.getStringExtra("agent").orEmpty()
  if(sid.isNotBlank()){vm.openId(sid);workLaunch++} else if(quick.isNotBlank()){vm.close();workLaunch++}
  if(intent.getBooleanExtra("signal_activity",false)){vm.showSignalsActivity=true;vm.externalHermesRoute++}
  // Close the old scene before observing delivery; an already-completed worker may open immediately.
  intent.getStringExtra("voice_work")?.let{vm.followVoiceDelivery(it)}
 }
}

@Composable fun AgentBadge(agent:String){Surface(shape=Radii.Pill,color=if(agent=="pi")PiSoft else AccentSoft,shadowElevation=1.dp){Row(Modifier.padding(horizontal=10.dp,vertical=5.dp),verticalAlignment=Alignment.CenterVertically){Box(Modifier.size(6.dp).background(if(agent=="pi")PiGreen else Ember,CircleShape));Text(if(agent=="pi")"Pi" else "Codex",Modifier.padding(start=6.dp),fontSize=11.sp,fontWeight=FontWeight.Bold,color=if(agent=="pi")PiGreen else EmberDeep,letterSpacing=.4.sp)}}}
@Composable fun Choice(label:String,options:List<String>,select:(String)->Unit){var show by remember{mutableStateOf(false)};Box{TextButton(onClick={show=true},contentPadding=PaddingValues(horizontal=8.dp)){Text(label,fontSize=12.sp,maxLines=1);Icon(Icons.Outlined.ExpandMore,null,Modifier.size(15.dp))};DropdownMenu(show,{show=false}){options.forEach{o->DropdownMenuItem(text={Text(o,fontSize=13.sp)},onClick={select(o);show=false})}}}}
fun dayLabel(ts:Double):String {val date=Date((ts*1000).toLong());val fmt=SimpleDateFormat("yyyy-MM-dd",Locale.CHINA);return when(fmt.format(date)){fmt.format(Date())->"今天";fmt.format(Date(System.currentTimeMillis()-86400000))->"昨天";else->SimpleDateFormat("M月d日",Locale.CHINA).format(date)}}
fun highlight(text:String,q:String):AnnotatedString=buildAnnotatedString{append(text);if(q.isNotBlank())q.trim().split(Regex("\\s+")).forEach{term->var start=0;while(start<text.length){val i=text.indexOf(term,start,true);if(i<0)break;addStyle(SpanStyle(background=Color(0xFFFFE6A5),color=Ink),i,i+term.length);start=i+term.length}}}

@Composable fun Approval(vm:WorkbenchModel,a:JSONObject){
 val haptics=rememberComHaptics()
 val p=a.optJSONObject("params")?:JSONObject();val questions=p.array("questions");val answers=remember(a.optString("id")){mutableStateMapOf<String,String>()}
 SpringIn(Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=6.dp)){
  Surface(shape=RoundedCornerShape(Radii.Xl),color=Card,border=BorderStroke(1.dp,AmberLine),shadowElevation=Elev.Raised){
   Column(Modifier.padding(Spacing.Xl)){
    Row(verticalAlignment=Alignment.CenterVertically){
     Box(Modifier.size(36.dp).background(AmberBg,CircleShape),contentAlignment=Alignment.Center){Icon(Icons.Outlined.NotificationImportant,null,Modifier.size(18.dp),tint=AmberText)}
     Column(Modifier.padding(start=12.dp)){
      Text("需要你回应",fontWeight=FontWeight.SemiBold,fontSize=15.sp,color=Ink)
      Text("来自 Mac mini 的执行请求",fontSize=11.sp,color=Muted)
     }
    }
    Surface(Modifier.padding(top=12.dp).fillMaxWidth(),shape=RoundedCornerShape(Radii.M),color=ToolSurface,border=BorderStroke(1.dp,Line)){Text(p.optString("command",p.optString("reason","请确认以下操作")),Modifier.padding(12.dp),fontSize=13.sp,lineHeight=19.sp,color=Ink,maxLines=6)}
    if(questions.isNotEmpty()){
     questions.forEach{q->Text(q.optString("question"),fontSize=14.sp);q.array("options").forEach{o->FilterChip(answers[q.optString("id")]==o.optString("label"),{answers[q.optString("id")]=o.optString("label")},label={Text(o.optString("label"))})};OutlinedTextField(answers[q.optString("id")]?:"",{answers[q.optString("id")]=it},label={Text("回答")},modifier=Modifier.fillMaxWidth().padding(top=6.dp))}
     Button(onClick={haptics(HapticCue.Commit);vm.run{vm.store.request("/approvals/${vm.enc(a.getString("id"))}",JSONObject().put("answers",JSONObject(answers.toMap())))}}){Text("提交回答")}
    }else Row(Modifier.padding(top=12.dp),horizontalArrangement=Arrangement.spacedBy(8.dp)){
     val (okPress,okMotion)=rememberPress()
     Button(onClick={haptics(HapticCue.Commit);vm.run{vm.store.request("/approvals/${vm.enc(a.getString("id"))}",JSONObject().put("decision","accept"))}},modifier=Modifier.weight(1f).height(46.dp).then(okMotion),shape=Radii.Pill,interactionSource=okPress,colors=ButtonDefaults.buttonColors(containerColor=Ember)){Text("允许本次",fontWeight=FontWeight.SemiBold)}
     val (noPress,noMotion)=rememberPress()
     OutlinedButton(onClick={haptics(HapticCue.Reject);vm.run{vm.store.request("/approvals/${vm.enc(a.getString("id"))}",JSONObject().put("decision","decline"))}},modifier=Modifier.weight(1f).height(46.dp).then(noMotion),shape=Radii.Pill,interactionSource=noPress){Text("拒绝",color=Muted)}
    }
   }
  }
 }
}

@Composable fun SessionMenu(vm:WorkbenchModel,s:JSONObject,dismiss:()->Unit){
 var title by remember{mutableStateOf(s.optString("display_title"))};var confirmEnd by remember{mutableStateOf(false)}
 AlertDialog(onDismissRequest=dismiss,title={Text("会话详情")},text={Column{
  Text("${s.optString("agent")} · ${s.optString("cwd")}",fontSize=12.sp,color=Muted)
  SelectionContainer{Text(s.optString("id"),fontSize=10.sp,color=Muted)}
  OutlinedTextField(title,{title=it},label={Text("会话标题")},modifier=Modifier.padding(top=12.dp))
  TextButton(onClick={vm.label(s.getString("id"),JSONObject().put("pinned",if(s.optInt("pinned")==1)0 else 1));dismiss()}){Text(if(s.optInt("pinned")==1)"取消置顶" else "置顶会话")}
  TextButton(onClick={vm.label(s.getString("id"),JSONObject().put("archived",if(s.optInt("archived")==1)0 else 1));dismiss()}){Text(if(s.optInt("archived")==1)"移出归档" else "归档（保留原始记录）")}
  if(s.optBoolean("managed"))TextButton(onClick={confirmEnd=true}){Text("结束远端会话",color=Danger)}
 }},confirmButton={TextButton(onClick={vm.label(s.getString("id"),JSONObject().put("title",title));dismiss()}){Text("保存标题")}},dismissButton={TextButton(onClick=dismiss){Text("关闭")}})
 if(confirmEnd)AlertDialog(onDismissRequest={confirmEnd=false},title={Text("结束远端会话？")},text={Text("这会关闭正在运行的终端进程。历史仍然保留。")},confirmButton={TextButton(onClick={vm.end();dismiss()}){Text("结束")}},dismissButton={TextButton(onClick={confirmEnd=false}){Text("取消")}})
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun NewSession(vm:WorkbenchModel,quick:String,dismiss:()->Unit){
 var agent by remember{mutableStateOf(quick.ifBlank{vm.store.prefs.getString("lastAgent","pi")?:"pi"})};var cwd by remember{mutableStateOf(vm.store.prefs.getString("lastCwd","/Users/eddiegao/AI_Work_System")?:"")}
 var prompt by rememberSaveable{mutableStateOf("")};var model by remember(agent){mutableStateOf(vm.selection(agent).model)};var effort by remember(agent){mutableStateOf(vm.selection(agent).effort)};var advanced by remember{mutableStateOf(false)};var sandbox by remember{mutableStateOf("danger-full-access")};var browse by remember{mutableStateOf(false)};var modelPicker by remember{mutableStateOf(false)}
 val motion=LocalMessageSendMotion.current
 val composerSource=remember{Any()}
 val create:()->Unit={
  val text=prompt.trim();val rid=UUID.randomUUID().toString()
  vm.chooseModel(agent,"",model,effort)
  if(text.isNotBlank())motion?.begin(rid,text,sourceKey=composerSource)
  val accepted=vm.create(agent,cwd,text,model,effort,sandbox,rid)
  if(accepted==null)motion?.cancel()else{motion?.retarget(rid,accepted);dismiss()}
 }
 // Material3's modal owns its window insets. The content consumes them once.
 ModalBottomSheet(onDismissRequest=dismiss,containerColor=Paper,sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true)){Column(Modifier.padding(horizontal=24.dp).verticalScroll(rememberScrollState()).testTag("advanced-session-sheet")){
 StaggerIn(0){Column{Text("开启新的工作",fontSize=Type.SheetTitle,fontWeight=FontWeight.SemiBold,letterSpacing=(-.3).sp);Text("运行在 Mac mini · 默认最高权限",Modifier.padding(top=6.dp,bottom=18.dp),fontSize=13.sp,color=Muted)}}
 val (createPress,createMotion)=rememberPress(.97f)
 StaggerIn(1){Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){listOf("pi","codex").forEach{a->FilterChip(agent==a,{agent=a},label={Text(if(a=="pi")"Pi" else "Codex",fontSize=17.sp)},modifier=Modifier.height(48.dp))}}}
 Text("工作目录",Modifier.padding(top=16.dp),fontSize=12.sp,color=Muted)
 TextButton(onClick={browse=true}){Icon(Icons.Outlined.FolderOpen,null);Text(cwd,Modifier.padding(start=8.dp),fontSize=13.sp,maxLines=2)}
 AdvancedSessionComposer(prompt,{prompt=it},motion,!vm.busy&&vm.connected,create,composerSource)
 TextButton(onClick={advanced=!advanced}){Text(if(advanced)"收起高级设置" else "高级设置")}
 if(advanced){
  TextButton(onClick={modelPicker=true;vm.loadModels(agent)}){Icon(Icons.Outlined.AutoAwesome,null);Text("${vm.catalogs[agent]?.firstOrNull{it.id==model}?.label?:model.ifBlank{"跟随 Mac 默认"}} · ${effort.ifBlank{"默认推理"}}",Modifier.padding(start=8.dp),maxLines=1)}
  if(agent=="codex")Choice(when(sandbox){"read-only"->"只读";"workspace-write"->"工作目录内写入";else->"最高权限（YOLO）"},listOf("最高权限（YOLO）","工作目录内写入","只读")){sandbox=when(it){"只读"->"read-only";"工作目录内写入"->"workspace-write";else->"danger-full-access"}}
 }
 StaggerIn(2){Button(onClick=create,enabled=!vm.busy&&vm.connected,modifier=Modifier.fillMaxWidth().padding(top=12.dp,bottom=28.dp).height(54.dp).then(createMotion),shape=Radii.Pill,interactionSource=createPress,colors=ButtonDefaults.buttonColors(containerColor=Ember)){Text(if(prompt.isBlank())"打开空会话" else "开始会话",fontSize=15.sp,fontWeight=FontWeight.SemiBold)}}
 }}
 if(browse)DirectoryPicker(vm,cwd,{cwd=it;browse=false}){browse=false}
 if(modelPicker)ModelPickerSheet(agent,vm.catalogs[agent].orEmpty(),model,effort,vm.catalogLoading[agent]==true,vm.catalogErrors[agent],{modelPicker=false},{chosen,level->model=chosen;effort=level;modelPicker=false},{vm.loadModels(agent,true)})
}

/** The exact measured text layout is also the source of the main-window send overlay. */
@Composable internal fun AdvancedSessionComposer(text:String,change:(String)->Unit,motion:MessageSendMotionState?,enabled:Boolean,send:()->Unit,sourceKey:Any?=null){
 var editing by remember{mutableStateOf(TextFieldValue(text,TextRange(text.length)))}
 LaunchedEffect(text){if(editing.text!=text)editing=TextFieldValue(text,TextRange(text.length))}
 val style=TextStyle(fontSize=15.sp,lineHeight=22.sp,color=Ink)
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
 AlertDialog(onDismissRequest=dismiss,title={Text("选择工作目录")},text={Column{Text(path,fontSize=12.sp,color=Muted);if(error.isNotBlank())Text(error);LazyColumn(Modifier.height(300.dp)){
 if(!data.isNull("parent")&&data.optString("parent").isNotBlank())item{TextButton(onClick={path=data.getString("parent")}){Text("↑ 上一级")}}
 val recent=data.optJSONArray("recent");if(recent!=null)items(recent.length()){i->TextButton(onClick={choose(recent.getString(i))}){Text("最近 · "+recent.getString(i).shortPath())}}
 val dirs=data.optJSONArray("directories");if(dirs!=null)items(dirs.length()){i->TextButton(onClick={path=dirs.getString(i)}){Text(dirs.getString(i).shortPath())}}
 }}},confirmButton={TextButton(onClick={choose(path)}){Text("使用此目录")}},dismissButton={TextButton(onClick=dismiss){Text("取消")}})
}
@Composable fun SettingsSheet(vm:WorkbenchModel,dismiss:()->Unit){
 val context=androidx.compose.ui.platform.LocalContext.current
 var base by remember{mutableStateOf(vm.store.base.ifBlank{"https://pi.eddiegao.work:8443/sessions"})};var code by remember{mutableStateOf("")};var notify by remember{mutableStateOf(vm.store.prefs.getBoolean("notifications",true))}
 Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal=22.dp).padding(bottom=28.dp)){
  Row(verticalAlignment=Alignment.CenterVertically){
   ComIcon(R.drawable.com_icon_settings_v1,null,Modifier.size(24.dp))
   Text("Com! · 设置",Modifier.padding(start=5.dp),fontSize=22.sp,fontWeight=FontWeight.SemiBold,color=Ink)
  }
 Text("语音记账",fontWeight=FontWeight.Bold)
 Text("电源键快捷小窗直接交给 Pi，可调用既有记账与收藏工具。语音记账入口会先显示金额，确认后交给 Pi；已接收不等于账本已写入，可在工作会话查看实际结果。",Modifier.padding(top=5.dp),fontSize=12.sp,color=Muted)
 TextButton(onClick={context.startActivity(Intent(context,ExpenseVoiceActivity::class.java))}){Icon(Icons.Outlined.Mic,null);Text("打开语音记账",Modifier.padding(start=8.dp))}
 TextButton(onClick={context.startActivity(Intent(android.provider.Settings.ACTION_VOICE_INPUT_SETTINGS))}){Text("系统默认助手设置")}
 HorizontalDivider(Modifier.padding(vertical=12.dp),color=Line)
 Text("Mac mini",fontWeight=FontWeight.Bold);Text(if(vm.connected)"连接正常" else "首次使用需配对",color=Muted,fontSize=12.sp)
 OutlinedTextField(base,{base=it},label={Text("HTTPS 服务地址")},modifier=Modifier.padding(top=12.dp))
 OutlinedTextField(code,{code=it},label={Text("一次性配对码")})
 TextButton(onClick={vm.run{vm.store.base=base;val r=vm.store.request("/pair",JSONObject().put("code",code),false);vm.store.token=r.getString("token");vm.refresh();vm.refreshPersonal();vm.refreshHermes();SignalSync.immediate(context);dismiss()}}){Text("配对并连接")}
 Text("字号 ${vm.font.toInt()}",Modifier.padding(top=16.dp));Slider(vm.font,{vm.font=it;vm.store.prefs.edit().putFloat("font",it).apply()},valueRange=14f..22f,steps=7)
 Row(verticalAlignment=Alignment.CenterVertically){Text("完成、失败与待回应通知",Modifier.weight(1f),fontSize=13.sp);Switch(notify,{notify=it;vm.store.prefs.edit().putBoolean("notifications",it).apply()})}
 Text("后台通知由 Android 定时调度，前台即时更新。\n历史索引 ${vm.index.optInt("done")}/${vm.index.optInt("total")}\n无法读取 ${vm.index.optInt("unreadable")} 份",fontSize=12.sp,color=Muted)
 SignalSettings(context)
 Text("离线仅检索已缓存的会话正文。凭据使用 Android Keystore 加密保存。",Modifier.padding(top=12.dp),fontSize=12.sp,color=Muted)
 Row(Modifier.fillMaxWidth().padding(top=16.dp),horizontalArrangement=Arrangement.End){
  TextButton(onClick=dismiss){Text("完成",fontSize=14.sp)}
 }
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
   listOf("↑" to "UP","↓" to "DOWN","←" to "LEFT","→" to "RIGHT","Enter" to "\r").forEach{(label,value)->TextButton(onClick={key(value)},modifier=Modifier.heightIn(min=48.dp)){Text(label,color=Color.White,fontSize=16.sp)}}
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
   },enabled=value!="MODEL"||vm.live.optString("status") !in listOf("running","waiting"),contentPadding=PaddingValues(horizontal=10.dp),modifier=Modifier.heightIn(min=48.dp)){Text(label,color=Color.White,fontSize=13.sp)}}
  }
 }
}
