package work.eddie.sessions

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.*
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.*
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.*
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import androidx.compose.ui.viewinterop.AndroidView
import android.content.*
import android.widget.TextView
import io.noties.markwon.Markwon
import io.noties.markwon.ext.tables.TablePlugin
import io.noties.markwon.ext.strikethrough.StrikethroughPlugin
import io.noties.markwon.linkify.LinkifyPlugin
import kotlinx.coroutines.*
import org.json.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun Workbench(vm:WorkbenchModel,quick:String,clearQuick:()->Unit){
 var settings by remember{mutableStateOf(vm.store.token.isBlank())}
 var advanced by remember{mutableStateOf(false)}
 var selectedAgent by rememberSaveable{mutableStateOf(vm.store.prefs.getString("lastAgent","pi")?:"pi")}
 var sidebar by rememberSaveable{mutableStateOf(false)}
 val drawer=rememberDrawerState(DrawerValue.Closed);val scope=rememberCoroutineScope()
 LaunchedEffect(quick){if(quick.isNotBlank()){selectedAgent=quick;vm.close();clearQuick()}}
 LaunchedEffect(vm.q,vm.agent,vm.role,vm.cwd,vm.days,vm.sort,vm.archived){delay(250);vm.refresh()}
 Surface(Modifier.fillMaxSize(),color=Paper){BoxWithConstraints(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()){
  val wide=maxWidth>=600.dp
  val openMenu:()->Unit={if(wide)sidebar=!sidebar else scope.launch{drawer.open()}}
  val newChat:()->Unit={vm.close();vm.q="";vm.queryInSession="";if(wide)sidebar=false else scope.launch{drawer.close()}}
  val pick:(JSONObject)->Unit={vm.open(it);if(wide)sidebar=false else scope.launch{drawer.close()}}
  BackHandler(drawer.isOpen||sidebar||vm.selected.isNotBlank()){if(drawer.isOpen)scope.launch{drawer.close()}else if(sidebar)sidebar=false else vm.close()}
  val content:@Composable ()->Unit={
   Row(Modifier.fillMaxSize()){
    AnimatedVisibility(visible=wide&&sidebar,enter=expandHorizontally(expandFrom=Alignment.Start,animationSpec=spring(dampingRatio=.86f,stiffness=Spring.StiffnessMediumLow))+fadeIn(tween(140)),exit=shrinkHorizontally(shrinkTowards=Alignment.Start,animationSpec=spring(dampingRatio=1f,stiffness=Spring.StiffnessMedium))+fadeOut(tween(120))){
     Row {Box(Modifier.width(260.dp).fillMaxHeight()){HistorySidebar(vm,pick,newChat,{settings=true})};VerticalDivider(color=Color(0xFFEAEAEA))}
    }
    Box(Modifier.weight(1f).fillMaxHeight()){
     if(vm.selected.isBlank())NewChatHome(vm,selectedAgent,{selectedAgent=it},openMenu,{advanced=true})
     else ChatPage(vm,openMenu,newChat)
     if(wide&&sidebar)Box(Modifier.matchParentSize().clickable(indication=null,interactionSource=remember{MutableInteractionSource()}){sidebar=false})
    }
   }
  }
  if(wide)content() else ModalNavigationDrawer(drawerState=drawer,drawerContent={ModalDrawerSheet(drawerContainerColor=Color(0xFFF9F9F9),drawerShape=RoundedCornerShape(0.dp),modifier=Modifier.fillMaxWidth(.86f)){HistorySidebar(vm,pick,newChat,{settings=true})}},content=content)
  if(vm.busy)LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp).align(Alignment.TopCenter),color=Ink,trackColor=Color.Transparent)
 }}
 if(settings)Settings(vm){settings=false}
 if(advanced)NewSession(vm,selectedAgent){advanced=false}
 if(vm.error.isNotBlank())AlertDialog(onDismissRequest={vm.error=""},containerColor=Color.White,title={Text("操作提示")},text={SelectionContainer{Text(vm.error)}},confirmButton={TextButton(onClick={vm.error=""}){Text("知道了")}})
}

@Composable fun Pill(items:List<String>,selected:Int,enabled:List<Boolean> = items.map{true},click:(Int)->Unit){
 Row(Modifier.background(Color(0xFFEAEAEA),RoundedCornerShape(50)).padding(3.dp)){
  items.forEachIndexed{i,label->
   val chipColor by animateColorAsState(if(selected==i)Color.White else Color.Transparent,spring(dampingRatio=.88f,stiffness=Spring.StiffnessMedium),label="选中会话视图")
   Box(Modifier.height(36.dp).widthIn(min=72.dp).clip(RoundedCornerShape(50)).background(chipColor).clickable(enabled=enabled[i]){click(i)}.padding(horizontal=18.dp),contentAlignment=Alignment.Center){Text(label,fontSize=14.sp,fontWeight=if(selected==i)FontWeight.Medium else FontWeight.Normal,color=if(enabled[i])Ink else Muted)}
  }
 }
}
@Composable fun RoundIcon(icon:androidx.compose.ui.graphics.vector.ImageVector,label:String,click:()->Unit){IconButton(onClick=click,modifier=Modifier.size(48.dp).background(Color.White,CircleShape)){Icon(icon,label,Modifier.size(23.dp),tint=Ink)}}

@Composable fun NewChatHome(vm:WorkbenchModel,agent:String,select:(String)->Unit,menu:()->Unit,advanced:()->Unit){
 var prompt by rememberSaveable{mutableStateOf(vm.store.prefs.getString("new-draft","")?:"")}
 var extra by remember{mutableStateOf(false)}
 Column(Modifier.fillMaxSize()){
  Box(Modifier.fillMaxWidth().padding(horizontal=14.dp,vertical=8.dp)){
   Box(Modifier.align(Alignment.CenterStart)){RoundIcon(Icons.Outlined.Menu,"菜单",menu)}
   Box(Modifier.align(Alignment.Center)){Pill(listOf("Pi","Codex"),if(agent=="pi")0 else 1){select(if(it==0)"pi" else "codex")}}
   Box(Modifier.align(Alignment.CenterEnd)){RoundIcon(Icons.Outlined.Tune,"新会话设置",advanced)}
  }
  Box(Modifier.weight(1f).fillMaxWidth(),contentAlignment=Alignment.Center){
   Column(horizontalAlignment=Alignment.CenterHorizontally){Text("有什么可以帮忙的？",fontSize=27.sp,fontWeight=FontWeight.SemiBold,letterSpacing=(-.5).sp);Text("${if(agent=="pi")"Pi" else "Codex"} · Mac mini · 最高权限",Modifier.padding(top=14.dp),fontSize=13.sp,color=Muted)}
  }
  if(!vm.connected)Text("未连接 · 已缓存的历史仍可阅读",Modifier.fillMaxWidth().padding(horizontal=22.dp,vertical=8.dp),fontSize=12.sp,color=Muted)
  Composer(prompt,{prompt=it;vm.store.prefs.edit().putString("new-draft",it).apply()},"询问 ${if(agent=="pi")"Pi" else "Codex"}",vm.connected&&!vm.busy,false,{extra=true},{
   vm.create(agent,vm.store.prefs.getString("lastCwd","/Users/eddiegao/AI_Work_System")?:"",prompt,"","","danger-full-access")
  },{})
  Text("运行于你的 Mac mini",Modifier.align(Alignment.CenterHorizontally).padding(bottom=9.dp),fontSize=10.sp,color=Muted)
 }
 if(extra)AlertDialog(onDismissRequest={extra=false},containerColor=Color.White,title={Text("会话选项")},text={Column{TextButton(onClick={extra=false;advanced()}){Icon(Icons.Outlined.FolderOpen,null);Text("工作目录与模型",Modifier.padding(start=12.dp))};Text("当前："+(vm.store.prefs.getString("lastCwd","AI_Work_System")?:"").shortPath(),fontSize=12.sp,color=Muted);Text("语音可使用键盘上的麦克风输入。",Modifier.padding(top=16.dp),fontSize=13.sp,color=Muted)}},confirmButton={TextButton(onClick={extra=false}){Text("完成")}})
}

@OptIn(ExperimentalFoundationApi::class)
@Composable fun HistorySidebar(vm:WorkbenchModel,pick:(JSONObject)->Unit,new:()->Unit,settings:()->Unit){
 var search by rememberSaveable{mutableStateOf(vm.q.isNotBlank())};var filters by remember{mutableStateOf(false)};var menuItem by remember{mutableStateOf<JSONObject?>(null)}
 Column(Modifier.fillMaxSize().background(Color(0xFFF9F9F9)).padding(horizontal=12.dp)){
  Row(Modifier.fillMaxWidth().padding(top=8.dp,bottom=10.dp),verticalAlignment=Alignment.CenterVertically){TextButton(onClick=new){Icon(Icons.Outlined.Edit,null,Modifier.size(21.dp));Text("新聊天",Modifier.padding(start=10.dp),fontSize=16.sp,color=Ink)};Spacer(Modifier.weight(1f));IconButton(onClick={search=!search}){Icon(Icons.Outlined.Search,"搜索")}}
  if(search){OutlinedTextField(vm.q,{vm.q=it;vm.working=false},Modifier.fillMaxWidth().padding(bottom=8.dp),placeholder={Text("搜索聊天内容",fontSize=14.sp)},singleLine=true,shape=RoundedCornerShape(30.dp),trailingIcon={IconButton(onClick={vm.q=""}){Icon(Icons.Outlined.Close,"清空")}})}
  SidebarEntry(Icons.Outlined.Bolt,"工作中",vm.working){vm.working=true}
  SidebarEntry(Icons.Outlined.Forum,"所有会话",!vm.working){vm.working=false}
  SidebarEntry(Icons.Outlined.FolderOpen,"工作目录与筛选",filters){filters=!filters}
  AnimatedVisibility(filters){Column{
   Choice(vm.agent.ifBlank{"全部 Agent"},listOf("全部 Agent","Pi","Codex")){vm.agent=if(it=="全部 Agent")"" else it.lowercase()}
   Choice(vm.cwd.shortPath().ifBlank{"所有目录"},listOf("所有目录")+vm.store.cached("list.json").array("sessions").map{it.optString("cwd")}.filter{it.isNotBlank()}.distinct()){vm.cwd=if(it=="所有目录")"" else it}
   Choice(if(vm.days==0)"所有时间" else "最近${vm.days}天",listOf("所有时间","最近7天","最近30天","最近90天")){vm.days=it.filter(Char::isDigit).toIntOrNull()?:0}
   Choice(if(vm.archived)"已归档" else "未归档",listOf("未归档","已归档")){vm.archived=it=="已归档"}
  }}
  if(search&&vm.q.isNotBlank()){
   Row(Modifier.horizontalScroll(rememberScrollState())){listOf("" to "全部","user" to "提问","assistant" to "回复","tool" to "执行").forEach{(key,label)->TextButton(onClick={vm.role=key}){Text(label,color=if(vm.role==key)Ink else Muted,fontWeight=if(vm.role==key)FontWeight.Bold else FontWeight.Normal)}}}
   Choice(if(vm.sort=="relevance")"按相关性" else "按时间",listOf("按相关性","按时间")){vm.sort=if(it=="按相关性")"relevance" else "recent"}
  }
  val rows=vm.rows.filter{!vm.working||it.optBoolean("managed")&&it.optString("status")!="ended"}.let{if(vm.working)it.sortedByDescending{s->s.optString("status")=="waiting"}else it}
  LazyColumn(Modifier.weight(1f),contentPadding=PaddingValues(bottom=16.dp)){
   item{Row(Modifier.fillMaxWidth().padding(start=10.dp,top=18.dp,bottom=8.dp),verticalAlignment=Alignment.CenterVertically){Text(if(vm.q.isNotBlank())"搜索结果 · ${rows.size}" else "最近",fontSize=12.sp,color=Muted);Spacer(Modifier.weight(1f));IconButton(onClick={vm.run{vm.store.request("/refresh",JSONObject());vm.refresh()}}){Icon(Icons.Outlined.Refresh,"刷新历史",Modifier.size(17.dp),tint=Muted)}}}
   items(rows,key={it.getString("id")}){s->
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(if(vm.selected==s.getString("id"))Color(0xFFECECEC) else Color.Transparent).combinedClickable(onClick={pick(s)},onLongClick={menuItem=s}).padding(horizontal=12.dp,vertical=13.dp)){
     Row(verticalAlignment=Alignment.CenterVertically){Text(s.optString("display_title").ifBlank{"新聊天"},fontSize=15.sp,maxLines=1,overflow=TextOverflow.Ellipsis,modifier=Modifier.weight(1f));if(s.optInt("pinned")==1)Icon(Icons.Outlined.PushPin,null,Modifier.size(13.dp),tint=Muted);if(s.optString("status")=="running")Box(Modifier.padding(start=7.dp).size(5.dp).background(Ink,CircleShape))}
     if(vm.q.isNotBlank()&&s.optString("snippet").isNotBlank()){Text(highlight(s.optString("snippet"),vm.q),Modifier.padding(top=7.dp),fontSize=12.sp,maxLines=3,overflow=TextOverflow.Ellipsis);Text("${s.optString("agent")} · 命中 ${s.optInt("hit_count")} 处",Modifier.padding(top=6.dp),fontSize=10.sp,color=Muted)}
     else if(s.optString("status")=="waiting")Text("需要你回应",Modifier.padding(top=5.dp),fontSize=11.sp,color=Muted)
    }
   }
   if(rows.isEmpty())item{Text(if(vm.q.isNotBlank())"没有找到匹配内容" else "这里会保存你的聊天",Modifier.padding(14.dp),fontSize=13.sp,color=Muted)}
   item{Text(if(!vm.connected)"离线：仅搜索已缓存内容" else if(vm.index.optBoolean("scanning"))"正在索引 ${vm.index.optInt("done")}/${vm.index.optInt("total")}" else "${vm.index.optInt("total")} 段 Mac mini 历史"+(if(vm.index.optInt("unreadable")>0)" · ${vm.index.optInt("unreadable")} 份不可读" else ""),Modifier.padding(12.dp),fontSize=10.sp,color=Muted)}
  }
  Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).clickable(onClick=settings).padding(12.dp),verticalAlignment=Alignment.CenterVertically){Box(Modifier.size(32.dp).background(Ink,CircleShape),contentAlignment=Alignment.Center){Text("E",color=Color.White,fontSize=14.sp,fontWeight=FontWeight.Bold)};Column(Modifier.weight(1f).padding(start=11.dp)){Text("Eddie",fontSize=14.sp,fontWeight=FontWeight.Medium);Text(if(vm.connected)"Mac mini · 已连接" else "连接与设置",fontSize=11.sp,color=Muted)};Icon(Icons.Outlined.MoreHoriz,"账户与连接设置")}
 }
 menuItem?.let{SessionMenu(vm,it){menuItem=null}}
}
@Composable fun SidebarEntry(icon:androidx.compose.ui.graphics.vector.ImageVector,text:String,selected:Boolean,click:()->Unit){Row(Modifier.fillMaxWidth().height(46.dp).clip(RoundedCornerShape(10.dp)).background(if(selected)Color(0xFFEDEDED)else Color.Transparent).clickable(onClick=click).padding(horizontal=12.dp),verticalAlignment=Alignment.CenterVertically){Icon(icon,null,Modifier.size(21.dp));Text(text,Modifier.padding(start=13.dp),fontSize=15.sp)}}

@Composable fun Composer(text:String,change:(String)->Unit,placeholder:String,enabled:Boolean,running:Boolean,more:()->Unit,send:()->Unit,stop:()->Unit){
 Surface(Modifier.fillMaxWidth().padding(horizontal=12.dp,vertical=8.dp).animateContentSize(animationSpec=spring(dampingRatio=.9f,stiffness=Spring.StiffnessMedium)),shape=RoundedCornerShape(27.dp),color=Color.White,shadowElevation=3.dp){Column(Modifier.padding(horizontal=16.dp,vertical=12.dp)){
  BasicTextField(text,change,Modifier.fillMaxWidth().heightIn(min=34.dp,max=136.dp).padding(top=4.dp,bottom=12.dp),textStyle=TextStyle(fontSize=17.sp,color=Ink,lineHeight=24.sp),cursorBrush=SolidColor(Ink),decorationBox={inner->Box{if(text.isBlank())Text(placeholder,fontSize=17.sp,color=Color(0xFF8F8F8F));inner()}})
  Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){IconButton(onClick=more,modifier=Modifier.size(40.dp)){Icon(Icons.Outlined.Add,"更多选项",Modifier.size(27.dp))};Spacer(Modifier.weight(1f));
   if(running)IconButton(onClick=stop,enabled=enabled,modifier=Modifier.size(40.dp).background(Ink,CircleShape)){Icon(Icons.Outlined.Stop,"停止当前执行",tint=Color.White,modifier=Modifier.size(22.dp))}
   else IconButton(onClick=send,enabled=enabled&&text.isNotBlank(),modifier=Modifier.size(40.dp).background(if(enabled&&text.isNotBlank())Ink else Color(0xFFE5E5E5),CircleShape)){Icon(Icons.Outlined.ArrowUpward,"发送",tint=if(enabled&&text.isNotBlank())Color.White else Color(0xFF9A9A9A),modifier=Modifier.size(23.dp))}
  }
 }}
}

@Composable fun ChatPage(vm:WorkbenchModel,menu:()->Unit,new:()->Unit){
 val sid=vm.selected;val s=vm.detail.optJSONObject("session")?:JSONObject();val caps=s.optJSONObject("capabilities")?:JSONObject()
 var terminal by rememberSaveable(sid){mutableStateOf(false)};var showMenu by remember{mutableStateOf(false)};var options by remember{mutableStateOf(false)};var search by rememberSaveable(sid){mutableStateOf(vm.queryInSession.isNotBlank())};var matchIndex by rememberSaveable(sid){mutableIntStateOf(0)}
 val messages=remember(vm.detail,vm.live){val merged=linkedMapOf<String,JSONObject>();vm.detail.array("messages").forEach{merged[it.optString("id")]=it};vm.live.array("items").forEach{merged[it.optString("id")]=it};merged.values.toList()}
 val displayRows=remember(messages){transcriptRows(messages.map{it.optString("role")},messages.map{it.optString("id")})}
 fun rowFor(id:String)=displayRows.indexOfFirst{row->row.indices.any{messages[it].optString("id")==id}}.coerceAtLeast(0)
 val list=rememberLazyListState();val scope=rememberCoroutineScope();val following by remember{derivedStateOf{!list.canScrollForward}}
 val status=vm.live.optString("status",s.optString("status"))
 val matches=messages.filter{m->vm.queryInSession.isNotBlank()&&vm.queryInSession.trim().split(Regex("\\s+")).all{(m.optString("text")+m.optString("title")).contains(it,true)}}
 LaunchedEffect(sid){val idx=vm.store.prefs.getInt("scroll:$sid",0);list.scrollToItem(idx.coerceAtMost(displayRows.size))}
 LaunchedEffect(sid,list){snapshotFlow{list.firstVisibleItemIndex}.collect{vm.store.prefs.edit().putInt("scroll:$sid",it).apply()}}
 LaunchedEffect(vm.targetMessage,messages.size){if(vm.targetMessage.isNotBlank()){val i=messages.indexOfFirst{it.optString("id")==vm.targetMessage};if(i>=0){list.scrollToItem(rowFor(vm.targetMessage));vm.targetMessage=""}}}
 LaunchedEffect(messages.lastOrNull()?.toString()){if(following&&vm.queryInSession.isBlank())list.animateScrollToItem(displayRows.size)}
 Column(Modifier.fillMaxSize()){
  Box(Modifier.fillMaxWidth().padding(horizontal=14.dp,vertical=8.dp)){
   Box(Modifier.align(Alignment.CenterStart)){RoundIcon(Icons.Outlined.Menu,"菜单",menu)}
   Box(Modifier.align(Alignment.Center)){Pill(listOf("对话","终端"),if(terminal)1 else 0,listOf(true,caps.optBoolean("terminal")&&vm.connected)){terminal=it==1}}
   Box(Modifier.align(Alignment.CenterEnd)){RoundIcon(Icons.Outlined.Edit,"新聊天",new)}
  }
  Row(Modifier.fillMaxWidth().padding(horizontal=22.dp).clickable{showMenu=true},verticalAlignment=Alignment.CenterVertically){Text(s.optString("display_title","正在读取…"),fontSize=12.sp,color=Muted,maxLines=1,overflow=TextOverflow.Ellipsis,modifier=Modifier.weight(1f));Text(s.optString("agent").replaceFirstChar{it.uppercase()},fontSize=11.sp,color=Muted);IconButton(onClick={search=!search},modifier=Modifier.size(36.dp)){Icon(Icons.Outlined.Search,"查找本会话",Modifier.size(17.dp),tint=Muted)}}
  if(search)Row(Modifier.padding(horizontal=16.dp),verticalAlignment=Alignment.CenterVertically){OutlinedTextField(vm.queryInSession,{vm.queryInSession=it;matchIndex=0},Modifier.weight(1f),placeholder={Text("查找内容",fontSize=13.sp)},singleLine=true,shape=RoundedCornerShape(24.dp));Text("${if(matches.isEmpty())0 else matchIndex+1}/${matches.size}",Modifier.padding(5.dp),fontSize=10.sp);listOf(-1 to Icons.Outlined.KeyboardArrowUp,1 to Icons.Outlined.KeyboardArrowDown).forEach{(delta,icon)->IconButton(enabled=matches.isNotEmpty(),onClick={matchIndex=(matchIndex+delta+matches.size)%matches.size;scope.launch{list.animateScrollToItem(rowFor(matches[matchIndex].optString("id")))}}){Icon(icon,if(delta<0)"上一个命中"else"下一个命中")}}}
  if(terminal&&caps.optBoolean("terminal"))Box(Modifier.weight(1f).fillMaxWidth()){Terminal(vm,sid)}
  else Box(Modifier.weight(1f).fillMaxWidth()){
   LazyColumn(state=list,contentPadding=PaddingValues(horizontal=22.dp,vertical=22.dp),verticalArrangement=Arrangement.spacedBy(25.dp)){
    items(displayRows,key={it.key}){row->
     if(row.process)ProcessGroup(row.indices.map{messages[it]},vm.queryInSession,vm.font,status=="running"&&row==displayRows.last())
     else Message(messages[row.indices.first()],vm.queryInSession,vm.font)
    }
    item{
     if(status=="running")Row(verticalAlignment=Alignment.CenterVertically){Box(Modifier.size(8.dp).background(Ink,CircleShape));Text("正在处理",Modifier.padding(start=9.dp),fontSize=13.sp,color=Muted)}
     else if(status=="waiting")Text("等待你的回应",fontSize=13.sp,color=Muted)
     if(!caps.optBoolean("input"))Text(s.optString("coverage","读取历史不会启动 Agent"),fontSize=11.sp,color=Muted)
     if(caps.optBoolean("input")&&messages.isEmpty())Text("发送第一句话开始。执行过程会实时显示；首条消息后可切换终端。",fontSize=13.sp,color=Muted)
    }
   }
   if(!following)OutlinedIconButton(onClick={scope.launch{list.animateScrollToItem(displayRows.size)}},modifier=Modifier.align(Alignment.BottomCenter).padding(bottom=8.dp).background(Color.White,CircleShape)){Icon(Icons.Outlined.ArrowDownward,"回到最新",Modifier.size(18.dp))}
  }
  if(!terminal){
   vm.live.array("approvals").forEach{Approval(vm,it)}
   if(!vm.connected)Text("连接中断 · 远端任务不会因此停止",Modifier.padding(horizontal=22.dp),fontSize=11.sp,color=Muted)
   if(caps.optBoolean("input"))Composer(vm.draft(),{vm.setDraft(it)},if(status=="running")"写下补充内容…"else"询问 ${s.optString("agent").replaceFirstChar{it.uppercase()}}",vm.connected&&!vm.busy,status in listOf("running","waiting"),{options=true},{vm.send()},{vm.stop()})
   else Column(Modifier.padding(horizontal=20.dp,vertical=12.dp)){
    Button(onClick={vm.resume()},enabled=vm.connected&&!vm.busy&&caps.optBoolean("resume"),shape=RoundedCornerShape(25.dp),modifier=Modifier.fillMaxWidth().height(48.dp)){Text("继续这个会话")}
    if(!caps.optBoolean("resume"))Text("只读历史 · 正在使用或状态未确认",Modifier.padding(top=8.dp),fontSize=11.sp,color=Muted)
   }
  }
 }
 if(showMenu)SessionMenu(vm,s){showMenu=false}
 if(options)AlertDialog(onDismissRequest={options=false},containerColor=Color.White,title={Text("会话选项")},text={Column{TextButton(onClick={options=false;terminal=true},enabled=caps.optBoolean("terminal")){Icon(Icons.Outlined.Terminal,null);Text("打开完整终端",Modifier.padding(start=12.dp))};TextButton(onClick={options=false;showMenu=true}){Icon(Icons.Outlined.Tune,null);Text("会话详情与管理",Modifier.padding(start=12.dp))};Text("语音可使用键盘麦克风。终端中支持原生命令与选择菜单。",fontSize=12.sp,color=Muted)}},confirmButton={TextButton(onClick={options=false}){Text("完成")}})
}


@Composable fun ProcessGroup(messages:List<JSONObject>,q:String,font:Float,running:Boolean){
 var expanded by rememberSaveable(messages.first().optString("id")){mutableStateOf(false)}
 val hasHit=q.isNotBlank()&&messages.any{m->q.trim().split(Regex("\\s+")).all{(m.optString("text")+m.optString("title")).contains(it,true)}}
 Column(Modifier.fillMaxWidth()){
  Row(Modifier.fillMaxWidth().heightIn(min=48.dp).clickable{expanded=!expanded}.padding(vertical=8.dp),verticalAlignment=Alignment.CenterVertically){
   Icon(if(expanded||hasHit)Icons.Outlined.ArrowDropDown else Icons.Outlined.ArrowRight,if(expanded)"收起处理过程" else "展开处理过程",Modifier.size(22.dp),tint=Muted)
   Text(if(running)"正在处理 · ${messages.size} 条过程" else "处理过程 · ${messages.size} 条记录",fontSize=14.sp,color=Muted)
  }
  AnimatedVisibility(expanded||hasHit,enter=expandVertically(animationSpec=spring(dampingRatio=.88f,stiffness=Spring.StiffnessMediumLow))+fadeIn(tween(160)),exit=shrinkVertically(animationSpec=spring(dampingRatio=1f,stiffness=Spring.StiffnessMedium))+fadeOut(tween(100))){Column(Modifier.padding(start=12.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
   messages.forEach{m->Message(m,q,font)}
  }}
 }
}

@Composable fun Message(m:JSONObject,q:String,font:Float){
 val role=m.optString("role");val tool=role in listOf("tool","progress");val body=m.optString("text");var expanded by rememberSaveable(m.optString("id")){mutableStateOf(false)};val context=LocalContext.current
 if(tool){
  Column(Modifier.fillMaxWidth()){
   Row(Modifier.fillMaxWidth().clickable{expanded=!expanded}.padding(vertical=7.dp),verticalAlignment=Alignment.CenterVertically){Icon(if(m.optString("state")=="running")Icons.Outlined.MoreHoriz else Icons.Outlined.Check,null,Modifier.size(16.dp),tint=Muted);Text(m.optString("title").ifBlank{"执行记录"}.take(120),Modifier.weight(1f).padding(start=9.dp),fontSize=13.sp,color=Muted,maxLines=2,overflow=TextOverflow.Ellipsis);Icon(if(expanded)Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,if(expanded)"收起" else "展开执行记录",Modifier.size(17.dp),tint=Muted)}
   AnimatedVisibility(expanded||q.isNotBlank(),enter=expandVertically(animationSpec=spring(dampingRatio=.9f,stiffness=Spring.StiffnessMedium))+fadeIn(tween(150)),exit=shrinkVertically(animationSpec=spring(dampingRatio=1f,stiffness=Spring.StiffnessMedium))+fadeOut(tween(100))){Surface(color=Color(0xFFF0F0F0),shape=RoundedCornerShape(12.dp)){SelectionContainer{Text(highlight(body,q),Modifier.padding(13.dp),fontFamily=FontFamily.Monospace,fontSize=(font-3).sp,lineHeight=(font+5).sp)}}}
  }
 }else{
  Column(Modifier.fillMaxWidth(),horizontalAlignment=if(role=="user")Alignment.End else Alignment.Start){
   Surface(Modifier.fillMaxWidth(if(role=="user").88f else 1f),color=if(role=="user")Color(0xFFEEEEEE) else Color.Transparent,shape=if(role=="user")RoundedCornerShape(23.dp) else androidx.compose.ui.graphics.RectangleShape){
    if(q.isNotBlank())SelectionContainer{Text(highlight(body,q),Modifier.padding(if(role=="user")14.dp else 0.dp),fontSize=font.sp,lineHeight=(font+9).sp)}
    else AndroidView(factory={c->MarkdownTextView(c).apply{setTextColor(android.graphics.Color.rgb(13,13,13));setTextIsSelectable(true);tag=Markwon.builder(c).usePlugin(TablePlugin.create(c)).usePlugin(StrikethroughPlugin.create()).usePlugin(LinkifyPlugin.create()).build()}},update={v->v.textSize=font;val pad=if(role=="user")(14*v.resources.displayMetrics.density).toInt()else 0;v.setPadding(pad,pad,pad,pad);v.setLineSpacing(5*v.resources.displayMetrics.density,1f);(v.tag as Markwon).setMarkdown(v,body)})
   }
   if(role=="assistant")Row(Modifier.padding(top=5.dp)){
    IconButton(onClick={(context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager).setPrimaryClip(ClipData.newPlainText("回复",body))},modifier=Modifier.size(34.dp)){Icon(Icons.Outlined.ContentCopy,"复制回复",Modifier.size(16.dp),tint=Muted)}
    IconButton(onClick={context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT,body),"分享回复"))},modifier=Modifier.size(34.dp)){Icon(Icons.Outlined.IosShare,"分享回复",Modifier.size(17.dp),tint=Muted)}
   }
  }
 }
}
