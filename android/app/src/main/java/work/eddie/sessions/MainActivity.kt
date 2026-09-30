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
import androidx.activity.compose.setContent
import androidx.activity.compose.BackHandler
import androidx.activity.viewModels
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.*
import androidx.compose.ui.text.style.TextOverflow
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
 override fun onCreate(savedInstanceState:Bundle?){super.onCreate(savedInstanceState)
   intent.getStringExtra("sid")?.let{vm.openId(it)};quick=intent.getStringExtra("agent")?:""
   if(android.os.Build.VERSION.SDK_INT>=33)requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS),10)
   val shortcuts=listOf("pi","codex").map{a->ShortcutInfo.Builder(this,a).setShortLabel("新建 ${a.replaceFirstChar{it.uppercase()}}").setIcon(AndroidIcon.createWithResource(this,R.drawable.ic_launcher)).setIntent(Intent(this,MainActivity::class.java).setAction(Intent.ACTION_VIEW).putExtra("agent",a)).build()}
   Thread { getSystemService(ShortcutManager::class.java).dynamicShortcuts=shortcuts }.start()
   androidx.work.WorkManager.getInstance(this).enqueueUniquePeriodicWork("session-updates",androidx.work.ExistingPeriodicWorkPolicy.KEEP,androidx.work.PeriodicWorkRequestBuilder<StatusWorker>(15,java.util.concurrent.TimeUnit.MINUTES).setConstraints(androidx.work.Constraints.Builder().setRequiredNetworkType(androidx.work.NetworkType.CONNECTED).build()).build())
   setContent{MaterialTheme(colorScheme=Palette){Workbench(vm,quick){quick=""}}}
 }
 override fun onStart(){super.onStart();vm.active=true}
 override fun onStop(){vm.active=false;super.onStop()}
 override fun onNewIntent(intent:Intent){super.onNewIntent(intent);intent.getStringExtra("sid")?.let{vm.openId(it)};quick=intent.getStringExtra("agent")?:""}
}

@Composable fun AgentBadge(agent:String){Surface(shape=RoundedCornerShape(6.dp),color=if(agent=="pi")PiSoft else AccentSoft){Text(if(agent=="pi")"Pi" else "Codex",Modifier.padding(horizontal=8.dp,vertical=3.dp),fontSize=11.sp,fontWeight=FontWeight.Bold,color=if(agent=="pi")PiGreen else AccentInk,letterSpacing=.3.sp)}}
@Composable fun Choice(label:String,options:List<String>,select:(String)->Unit){var show by remember{mutableStateOf(false)};Box{TextButton(onClick={show=true},contentPadding=PaddingValues(horizontal=8.dp)){Text(label,fontSize=12.sp,maxLines=1);Icon(Icons.Outlined.ExpandMore,null,Modifier.size(15.dp))};DropdownMenu(show,{show=false}){options.forEach{o->DropdownMenuItem(text={Text(o,fontSize=13.sp)},onClick={select(o);show=false})}}}}
fun dayLabel(ts:Double):String {val date=Date((ts*1000).toLong());val fmt=SimpleDateFormat("yyyy-MM-dd",Locale.CHINA);return when(fmt.format(date)){fmt.format(Date())->"今天";fmt.format(Date(System.currentTimeMillis()-86400000))->"昨天";else->SimpleDateFormat("M月d日",Locale.CHINA).format(date)}}
fun highlight(text:String,q:String):AnnotatedString=buildAnnotatedString{append(text);if(q.isNotBlank())q.trim().split(Regex("\\s+")).forEach{term->var start=0;while(start<text.length){val i=text.indexOf(term,start,true);if(i<0)break;addStyle(SpanStyle(background=Color(0xFFFFE6A5),color=Ink),i,i+term.length);start=i+term.length}}}

@Composable fun Approval(vm:WorkbenchModel,a:JSONObject){
 val p=a.optJSONObject("params")?:JSONObject();val questions=p.array("questions");val answers=remember(a.optString("id")){mutableStateMapOf<String,String>()}
 Surface(color=ApprovalBg,modifier=Modifier.fillMaxWidth().padding(horizontal=12.dp),shape=RoundedCornerShape(16.dp),border=BorderStroke(1.dp,Color(0xFFF0DFAE))){
 Column(Modifier.padding(12.dp)){Text("需要你回应",fontWeight=FontWeight.Bold);Text(p.optString("command",p.optString("reason","请确认以下操作")),fontSize=13.sp,maxLines=5)
 if(questions.isNotEmpty()){
  questions.forEach{q->Text(q.optString("question"),fontSize=14.sp);q.array("options").forEach{o->FilterChip(answers[q.optString("id")]==o.optString("label"),{answers[q.optString("id")]=o.optString("label")},label={Text(o.optString("label"))})};OutlinedTextField(answers[q.optString("id")]?:"",{answers[q.optString("id")]=it},label={Text("回答")})}
  Button(onClick={vm.run{vm.store.request("/approvals/${vm.enc(a.getString("id"))}",JSONObject().put("answers",JSONObject(answers.toMap())))}}){Text("提交回答")}
 }else Row{listOf("accept" to "允许本次","decline" to "拒绝").forEach{(key,label)->TextButton(onClick={vm.run{vm.store.request("/approvals/${vm.enc(a.getString("id"))}",JSONObject().put("decision",key))}}){Text(label)}}}
 }}
}

@Composable fun SessionMenu(vm:WorkbenchModel,s:JSONObject,dismiss:()->Unit){
 var title by remember{mutableStateOf(s.optString("display_title"))};var confirmEnd by remember{mutableStateOf(false)}
 AlertDialog(onDismissRequest=dismiss,title={Text("会话详情")},text={Column{
  Text("${s.optString("agent")} · ${s.optString("cwd")}",fontSize=12.sp,color=Muted)
  SelectionContainer{Text(s.optString("id"),fontSize=10.sp,color=Muted)}
  OutlinedTextField(title,{title=it},label={Text("会话标题")},modifier=Modifier.padding(top=12.dp))
  TextButton(onClick={vm.label(s.getString("id"),JSONObject().put("pinned",if(s.optInt("pinned")==1)0 else 1));dismiss()}){Text(if(s.optInt("pinned")==1)"取消置顶" else "置顶会话")}
  TextButton(onClick={vm.label(s.getString("id"),JSONObject().put("archived",if(s.optInt("archived")==1)0 else 1));dismiss()}){Text(if(s.optInt("archived")==1)"移出归档" else "归档（保留原始记录）")}
  if(s.optBoolean("managed"))TextButton(onClick={confirmEnd=true}){Text("结束远端会话",color=Color(0xFFB24A3D))}
 }},confirmButton={TextButton(onClick={vm.label(s.getString("id"),JSONObject().put("title",title));dismiss()}){Text("保存标题")}},dismissButton={TextButton(onClick=dismiss){Text("关闭")}})
 if(confirmEnd)AlertDialog(onDismissRequest={confirmEnd=false},title={Text("结束远端会话？")},text={Text("这会关闭正在运行的终端进程。历史仍然保留。")},confirmButton={TextButton(onClick={vm.end();dismiss()}){Text("结束")}},dismissButton={TextButton(onClick={confirmEnd=false}){Text("取消")}})
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun NewSession(vm:WorkbenchModel,quick:String,dismiss:()->Unit){
 var agent by remember{mutableStateOf(quick.ifBlank{vm.store.prefs.getString("lastAgent","pi")?:"pi"})};var cwd by remember{mutableStateOf(vm.store.prefs.getString("lastCwd","/Users/eddiegao/AI_Work_System")?:"")}
 var prompt by rememberSaveable{mutableStateOf("")};var model by remember{mutableStateOf("")};var effort by remember{mutableStateOf("")};var advanced by remember{mutableStateOf(false)};var sandbox by remember{mutableStateOf("danger-full-access")};var browse by remember{mutableStateOf(false)}
 ModalBottomSheet(onDismissRequest=dismiss,containerColor=Paper){Column(Modifier.padding(horizontal=24.dp).verticalScroll(rememberScrollState()).imePadding()){
 Text("开启新的工作",fontSize=25.sp,fontWeight=FontWeight.Bold);Text("运行在 Mac mini · 默认最高权限",Modifier.padding(top=6.dp,bottom=18.dp),fontSize=13.sp,color=Muted)
 Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){listOf("pi","codex").forEach{a->FilterChip(agent==a,{agent=a},label={Text(if(a=="pi")"Pi" else "Codex",fontSize=17.sp)},modifier=Modifier.height(48.dp))}}
 Text("工作目录",Modifier.padding(top=16.dp),fontSize=12.sp,color=Muted)
 TextButton(onClick={browse=true}){Icon(Icons.Outlined.FolderOpen,null);Text(cwd,Modifier.padding(start=8.dp),fontSize=13.sp,maxLines=2)}
 OutlinedTextField(prompt,{prompt=it},Modifier.fillMaxWidth().heightIn(min=120.dp),placeholder={Text("想做什么？也可以先打开空会话。")},shape=RoundedCornerShape(16.dp))
 TextButton(onClick={advanced=!advanced}){Text(if(advanced)"收起高级设置" else "高级设置")}
 if(advanced){OutlinedTextField(model,{model=it},label={Text("模型（留空沿用 Mac 配置）")});if(agent=="pi")Choice(effort.ifBlank{"默认推理强度"},listOf("默认推理强度","off","minimal","low","medium","high","xhigh")){effort=if(it=="默认推理强度")"" else it};if(agent=="codex")Choice(when(sandbox){"read-only"->"只读";"workspace-write"->"工作目录内写入";else->"最高权限（YOLO）"},listOf("最高权限（YOLO）","工作目录内写入","只读")){sandbox=when(it){"只读"->"read-only";"工作目录内写入"->"workspace-write";else->"danger-full-access"}}}
 Button(onClick={vm.create(agent,cwd,prompt,model,effort,sandbox);dismiss()},enabled=!vm.busy&&vm.connected,modifier=Modifier.fillMaxWidth().padding(top=12.dp,bottom=28.dp).height(52.dp),shape=RoundedCornerShape(16.dp)){Text(if(prompt.isBlank())"打开空会话" else "开始会话")}
 }}
 if(browse)DirectoryPicker(vm,cwd,{cwd=it;browse=false}){browse=false}
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
@Composable fun Settings(vm:WorkbenchModel,dismiss:()->Unit){
 var base by remember{mutableStateOf(vm.store.base.ifBlank{"https://pi.eddiegao.work:8443/sessions"})};var code by remember{mutableStateOf("")};var notify by remember{mutableStateOf(vm.store.prefs.getBoolean("notifications",true))}
 AlertDialog(onDismissRequest=dismiss,title={Text("连接与设置")},text={Column(Modifier.verticalScroll(rememberScrollState())){
 Text("Mac mini",fontWeight=FontWeight.Bold);Text(if(vm.connected)"连接正常" else "首次使用需配对",color=Muted,fontSize=12.sp)
 OutlinedTextField(base,{base=it},label={Text("HTTPS 服务地址")},modifier=Modifier.padding(top=12.dp))
 OutlinedTextField(code,{code=it},label={Text("一次性配对码")})
 TextButton(onClick={vm.run{vm.store.base=base;val r=vm.store.request("/pair",JSONObject().put("code",code),false);vm.store.token=r.getString("token");vm.refresh();dismiss()}}){Text("配对并连接")}
 Text("字号 ${vm.font.toInt()}",Modifier.padding(top=16.dp));Slider(vm.font,{vm.font=it;vm.store.prefs.edit().putFloat("font",it).apply()},valueRange=14f..22f,steps=7)
 Row(verticalAlignment=Alignment.CenterVertically){Text("完成、失败与待回应通知",Modifier.weight(1f),fontSize=13.sp);Switch(notify,{notify=it;vm.store.prefs.edit().putBoolean("notifications",it).apply()})}
 Text("后台通知由 Android 定时调度，前台即时更新。\n历史索引 ${vm.index.optInt("done")}/${vm.index.optInt("total")}\n无法读取 ${vm.index.optInt("unreadable")} 份",fontSize=12.sp,color=Muted)
 Text("离线仅检索已缓存的会话正文。凭据使用 Android Keystore 加密保存。",Modifier.padding(top=12.dp),fontSize=12.sp,color=Muted)
 }},confirmButton={TextButton(onClick=dismiss){Text("完成")}})
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
