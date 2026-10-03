package work.eddie.sessions

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.*
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.*
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
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
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.collectLatest

private val whitespace=Regex("\\s+")

fun relTime(ts:Double):String{
 val age=(System.currentTimeMillis()-ts*1000).toLong()
 return when{age<60_000->"刚刚";age<3600_000->"${age/60000}分钟前";age<86400_000->SimpleDateFormat("HH:mm",Locale.CHINA).format(Date((ts*1000).toLong()));else->dayLabel(ts)}
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun Workbench(vm:WorkbenchModel,quick:String,workLaunch:Int,clearQuick:()->Unit){
 val sendMotion=rememberMessageSendMotionState(vm.active)
 var settings by remember{mutableStateOf(vm.store.token.isBlank())}
 var advanced by remember{mutableStateOf(false)}
 var page by remember{mutableStateOf(vm.rootPage)}
 var selectedAgent by rememberSaveable{mutableStateOf(vm.store.prefs.getString("lastAgent","claude").takeIf{it in listOf("claude","codex")}?:"claude")}
 var history by rememberSaveable{mutableStateOf(false)}
 var more by rememberSaveable{mutableStateOf(false)}
 var permissions by rememberSaveable{mutableStateOf(false)}
 val navigate:(String)->Unit={target->sendMotion.cancel();page=target;more=false;history=false}
 LaunchedEffect(quick){if(quick.isNotBlank()){selectedAgent=if(quick=="pi")"claude"else quick;page=if(quick=="pi")"hermes"else"work";clearQuick()}}
 LaunchedEffect(workLaunch){if(workLaunch>0)page="work"}
 LaunchedEffect(vm.externalWorkRoute){if(vm.externalWorkRoute>0)page="work"}
 LaunchedEffect(vm.externalHermesRoute){if(vm.externalHermesRoute>0)page="hermes"}
 LaunchedEffect(page){
  vm.rootPage=page;vm.hermesVisible=page=="hermes"
  if(vm.store.token.isNotEmpty())when(page){
   "hermes"->vm.refreshHermesNow()
   "sources"->{vm.refreshPersonalNow();vm.refreshHermesNow();vm.refreshSignalsNow();vm.refreshWorkProposalsNow()}
  }
 }
 LaunchedEffect(page,vm.active){
  while(vm.active){
   if(vm.store.token.isNotEmpty())vm.refreshWorkProposals()
   delay(if(page=="activity")3000 else 10000)
  }
 }
 LaunchedEffect(vm.q,vm.agent,vm.role,vm.cwd,vm.days,vm.sort,vm.archived){delay(250);vm.refresh()}
 val openActivity:()->Unit={sendMotion.cancel();page="activity"}
 val newChat:()->Unit={sendMotion.cancel();vm.close();vm.q="";vm.queryInSession="";history=false}
 val pick:(JSONObject)->Unit={sendMotion.cancel();vm.open(it);history=false}
 BackHandler(page!="hermes"||page=="work"&&vm.selected.isNotBlank()){
  sendMotion.cancel()
  if(page=="work"&&vm.selected.isNotBlank())vm.close()else page="hermes"
 }
 CompositionLocalProvider(LocalMessageSendMotion provides sendMotion){
 Surface(Modifier.fillMaxSize(),color=Paper){Box(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding().testTag("workbench-inset-root")){
  Column(Modifier.fillMaxSize()){
   Box(Modifier.weight(1f).fillMaxWidth()){
    when(page){
     "work"->Column(Modifier.fillMaxSize()){
      Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal=16.dp).testTag("work-fixed-header"),verticalAlignment=Alignment.CenterVertically){
       ComIcon(R.drawable.com_icon_work_v1,null,Modifier.size(23.dp))
       Text("工作 · Claude / Codex",Modifier.weight(1f).padding(start=10.dp),fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=Ink)
       IconButton(onClick={sendMotion.cancel();history=true}){Icon(Icons.Outlined.History,"工作会话历史",tint=Muted)}
      }
      Box(Modifier.weight(1f)){
       ConversationScene(vm,selectedAgent,{selectedAgent=it;vm.store.prefs.edit().putString("lastAgent",it).apply()},{sendMotion.cancel();history=true},{sendMotion.cancel();advanced=true},pick,newChat)
      }
     }
     "calendar"->PhoneCalendarPage{navigate("sources")}
     "finance"->PersonalDetailPage(vm,page){navigate("sources")}
     "sources"->PersonalSourcesPage(vm){navigate("hermes")}
     "activity"->TaskActivityPage(vm){navigate("hermes")}
     else->HermesChat(vm,{sendMotion.cancel();more=true},true,openActivity)
    }
   }
   ImeAwareBottomNavigation{enabled->ComBottomNavigation(page,navigate,openActivity,{sendMotion.cancel();more=true},enabled)}
  }
  if(vm.busy)LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp).align(Alignment.TopCenter),color=Ink,trackColor=Color.Transparent)
  MessageSendMotionOverlay(sendMotion,Modifier.matchParentSize())
 }}
 if(history)ModalBottomSheet(onDismissRequest={history=false},containerColor=Paper,sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true)){
  Box(Modifier.fillMaxWidth().fillMaxHeight(.88f)){HistorySidebar(vm,pick,newChat,{history=false;settings=true})}
 }
 if(more)ModalBottomSheet(onDismissRequest={more=false},containerColor=Paper){
  Column(Modifier.fillMaxWidth().padding(horizontal=24.dp).padding(bottom=32.dp),verticalArrangement=Arrangement.spacedBy(6.dp)){
   Text("Com!",Modifier.padding(bottom=12.dp),fontSize=24.sp,fontWeight=FontWeight.SemiBold,color=Ink)
   listOf("calendar" to "日历","finance" to "账本","permissions" to "权限与上下文","settings" to "设置").forEach{(target,label)->
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).clickable{more=false;when(target){"settings"->settings=true;"permissions"->permissions=true;else->navigate(target)}}.padding(horizontal=16.dp,vertical=18.dp),verticalAlignment=Alignment.CenterVertically){
     if(target=="permissions")Icon(Icons.Outlined.AdminPanelSettings,null,Modifier.size(24.dp),tint=Muted)
     else ComPrimaryIcon(target,null,24.dp,Muted)
     Text(label,Modifier.weight(1f).padding(start=18.dp),fontSize=17.sp,color=Ink)
     Icon(Icons.Outlined.ChevronRight,null,Modifier.size(20.dp),tint=Faint)
    }
   }
  }
 }
 if(permissions)ModalBottomSheet(onDismissRequest={permissions=false},containerColor=Paper,sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true)){
  Box(Modifier.fillMaxWidth().fillMaxHeight(.88f)){PermissionsSheetContent()}
 }
 if(settings)ModalBottomSheet(onDismissRequest={settings=false},containerColor=Paper,sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true)){
  Box(Modifier.fillMaxWidth().fillMaxHeight(.92f)){SettingsSheet(vm){settings=false}}
 }
 if(advanced)NewSession(vm,selectedAgent){advanced=false}
 if(vm.error.isNotBlank())AlertDialog(onDismissRequest={vm.error=""},containerColor=Card,title={Text("操作提示",fontWeight=FontWeight.SemiBold)},text={SelectionContainer{Text(vm.error)}},confirmButton={TextButton(onClick={vm.error=""}){Text("知道了")}})
 }
}

/** Read the animated insets during layout, so the first IME frame never drops the composer. */
@Composable internal fun ImeAwareBottomNavigation(modifier:Modifier=Modifier,ime:WindowInsets=WindowInsets.ime,navigation:WindowInsets=WindowInsets.navigationBars,content:@Composable (Boolean)->Unit){
 val density=LocalDensity.current
 var naturalHeight by remember{mutableIntStateOf(0)}
 val enabled=ime.getBottom(density)<=navigation.getBottom(density)
 Box(modifier.fillMaxWidth().clipToBounds().layout{measurable,constraints->
  val child=measurable.measure(constraints.copy(minHeight=0))
  naturalHeight=child.height
  val height=keyboardNavigationHeight(child.height,ime.getBottom(this),navigation.getBottom(this))
  layout(child.width,height){child.placeRelative(0,0)}
 }.graphicsLayer{alpha=if(naturalHeight>0)keyboardNavigationHeight(naturalHeight,ime.getBottom(density),navigation.getBottom(density)).toFloat()/naturalHeight else 0f}
  .testTag("workbench-bottom-navigation")
  .then(if(enabled)Modifier else Modifier.clearAndSetSemantics{})){content(enabled)}
}

internal fun keyboardNavigationHeight(naturalHeight:Int,imeBottom:Int,navigationBottom:Int):Int=
 (naturalHeight-(imeBottom-navigationBottom).coerceAtLeast(0)).coerceAtLeast(0)

private data class MessageViewportPosition(val width:Int,val height:Int,val first:Int,val offset:Int,val following:Boolean,val count:Int,val lastHeight:Int,val beforePadding:Int,val afterPadding:Int,val scrolling:Boolean)

/** Keep bottom readers at the bottom on IME/size changes; preserve a history reader's exact anchor. */
@Composable fun MessageViewportAnchor(listState:LazyListState,key:Any,active:Boolean=true,motion:MessageSendMotionState?=null){
 LaunchedEffect(listState,key,active){
  if(!active)return@LaunchedEffect
  var previous:MessageViewportPosition?=null
  var resizeAnchor:MessageViewportPosition?=null
  snapshotFlow{
   val info=listState.layoutInfo
   MessageViewportPosition(info.viewportSize.width,info.viewportSize.height,listState.firstVisibleItemIndex,listState.firstVisibleItemScrollOffset,
    !listState.canScrollForward,info.totalItemsCount,info.visibleItemsInfo.lastOrNull{it.index==info.totalItemsCount-1}?.size?:0,
    info.beforeContentPadding,info.afterContentPadding,listState.isScrollInProgress)
  }.distinctUntilChanged().collect{position->
   val old=previous
   previous=position
   if(position.scrolling||motion?.messageId!=null)resizeAnchor=null
   if(old!=null&&(old.width!=position.width||old.height!=position.height)&&position.count>0&&!position.scrolling&&motion?.messageId==null){
    // A native IME can deliver another size frame before the requested anchor
    // remeasure has run. Keep the original reading intent across those frames.
    val anchor=resizeAnchor?:old
    resizeAnchor=anchor
    if(anchor.following){
     val available=(position.height-position.beforePadding-position.afterPadding).coerceAtLeast(1)
     listState.requestScrollToItem(position.count-1,(anchor.lastHeight-available).coerceAtLeast(0))
    }else if(anchor.count==position.count)listState.requestScrollToItem(anchor.first.coerceAtMost(position.count-1),anchor.offset)
   }else resizeAnchor?.let{anchor->if(anchor.following&&position.following||!anchor.following&&position.first==anchor.first&&position.offset==anchor.offset)resizeAnchor=null}
  }
 }
}

@Composable private fun ComBottomNavigation(page:String,navigate:(String)->Unit,activity:()->Unit,more:()->Unit,enabled:Boolean=true){
 BoxWithConstraints(Modifier.fillMaxWidth().padding(top=10.dp,bottom=10.dp),contentAlignment=Alignment.Center){
 val roomy=maxWidth>=360.dp&&LocalDensity.current.fontScale<=1.3f
 val itemHeight=maxOf(48f,24f+22f*LocalDensity.current.fontScale).dp
 val labelWidth=(maxWidth-278.dp).coerceAtLeast(26.dp)
 Surface(shape=RoundedCornerShape(50),color=Card,border=BorderStroke(1.dp,Color(0xFFE5E8EC)),shadowElevation=8.dp){
  Row(Modifier.padding(horizontal=8.dp,vertical=6.dp),horizontalArrangement=Arrangement.spacedBy(2.dp),verticalAlignment=Alignment.CenterVertically){
   listOf("hermes" to "对话","sources" to "今天","activity" to "任务","work" to "工作","settings" to "更多").forEach{(target,label)->
    val selected=page==target||target=="sources"&&page in listOf("calendar","finance")
    val background by animateColorAsState(if(selected)Color(0xFF252A31) else Color.Transparent,tween(180),label="导航选中")
    val foreground=if(selected)Color.White else Color(0xFF68727D)
    Row(Modifier.widthIn(min=48.dp).height(itemHeight).clip(RoundedCornerShape(50)).background(background)
     .selectable(selected=selected,enabled=enabled,role=androidx.compose.ui.semantics.Role.Tab,onClick={when(target){"activity"->activity();"settings"->more();else->navigate(target)}})
     .padding(horizontal=if(roomy)15.dp else 12.dp,vertical=12.dp),verticalAlignment=Alignment.CenterVertically){
     ComPrimaryIcon(target,label,20.dp,foreground)
     if(roomy)AnimatedVisibility(selected,enter=expandHorizontally(tween(180))+fadeIn(tween(120)),exit=shrinkHorizontally(tween(140))+fadeOut(tween(100))){
      Text(label,Modifier.padding(start=6.dp),fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=foreground,maxLines=1)
     }
     else if(selected)Text(label,Modifier.padding(start=6.dp).widthIn(max=labelWidth),fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=foreground,maxLines=1,overflow=TextOverflow.Ellipsis)
    }
   }
  }
 }
 }
}

@Composable private fun ComPrimaryIcon(target:String,label:String?,size:Dp,tint:Color=Ink,selected:Boolean=false){
 when(target){
  "sources"->Icon(Icons.Outlined.WbSunny,label,Modifier.size(size),tint=tint)
  "activity"->Icon(Icons.Outlined.Checklist,label,Modifier.size(size),tint=tint)
  "settings"->Icon(Icons.Outlined.PersonOutline,label,Modifier.size(size),tint=tint)
  else->ComIcon(when(target){"hermes"->R.drawable.com_icon_chat_v1;"work"->R.drawable.com_icon_work_v1;"finance"->R.drawable.com_icon_finance_v1;else->R.drawable.com_icon_today_v1},label,Modifier.size(size),tint=tint,selected=selected)
 }
}

@Composable fun Pill(items:List<String>,selected:Int,enabled:List<Boolean> = items.map{true},click:(Int)->Unit){
 val cell=84.dp
 val haptics=rememberComHaptics()
 val position by animateDpAsState(cell*selected,spring(dampingRatio=.67f,stiffness=430f),label="伙伴选中色块滑动")
 val jelly=remember{Animatable(0f)}
 var previous by remember{mutableIntStateOf(selected)}
 LaunchedEffect(selected){if(previous!=selected){previous=selected;jelly.animateTo(1f,tween(65,easing=FastOutSlowInEasing));jelly.animateTo(0f,spring(dampingRatio=.45f,stiffness=520f))}}
 Box(Modifier.background(Track,RoundedCornerShape(50)).padding(3.dp)){
  Box(Modifier.offset(x=position).width(cell).height(48.dp).graphicsLayer{scaleX=1f+jelly.value*.12f;scaleY=1f-jelly.value*.08f}.shadow(1.dp,RoundedCornerShape(50),spotColor=Color(0x1A000000)).background(Card,RoundedCornerShape(50)))
  Row{
   items.forEachIndexed{i,label->
    val (press,motion)=rememberPress(.97f)
    Box(Modifier.width(cell).height(48.dp).then(motion).clip(RoundedCornerShape(50)).clickable(interactionSource=press,indication=null,enabled=enabled[i]){if(selected!=i){haptics(HapticCue.Selection);click(i)}},contentAlignment=Alignment.Center){Text(label,fontSize=Type.BodySm,fontWeight=if(selected==i)FontWeight.SemiBold else FontWeight.Normal,color=if(!enabled[i])Faint else if(selected==i)Ink else Muted)}
   }
  }
 }
}
@Composable fun RoundIcon(icon:androidx.compose.ui.graphics.vector.ImageVector,label:String,click:()->Unit){
 val (press,pressMod)=rememberPress(.97f)
 IconButton(onClick=click,modifier=Modifier.size(46.dp).then(pressMod).clip(CircleShape).background(Card).border(1.dp,Line,CircleShape),interactionSource=press){Icon(icon,label,Modifier.size(22.dp),tint=Ink)}
}

@Composable fun QuickChip(icon:androidx.compose.ui.graphics.vector.ImageVector,label:String,enabled:Boolean=true,click:()->Unit){
 val (press,pressMod)=rememberPress(.97f)
 Row(Modifier.then(pressMod).clip(RoundedCornerShape(50)).background(if(enabled)ChipBg else ChipBg.copy(alpha=.45f)).clickable(interactionSource=press,indication=null,enabled=enabled){click()}.padding(horizontal=15.dp,vertical=10.dp),verticalAlignment=Alignment.CenterVertically){
  Icon(icon,null,Modifier.size(15.dp),tint=if(enabled)Ink else Faint);Text(label,Modifier.padding(start=7.dp),fontSize=Type.BodySm,color=if(enabled)Ink else Faint)
 }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable fun NewChatHome(vm:WorkbenchModel,agent:String,select:(String)->Unit,menu:()->Unit,advanced:()->Unit,pick:(JSONObject)->Unit){
 val name=agentDisplayName(agent)
 val fresh=vm.connected&&vm.allRowsFresh&&!vm.archived
 val sessions=remember(vm.allRows,agent){vm.allRows.filter{it.optString("agent")==agent&&it.optInt("archived")==0}.sortedByDescending{it.optDouble("updated")}}
 val focus=sessions.firstOrNull{it.optBoolean("managed")&&it.optString("status") in listOf("failed","waiting")}
  ?:sessions.firstOrNull{it.optString("status")=="running"}?:sessions.firstOrNull()
 val status=focus?.optString("status").orEmpty()
 val avatar=rememberCompanionState("home:$agent:${focus?.optString("id")}",status,fresh)
 val title=when{vm.voiceDelivery.isNotBlank()->"这句话，\nPi 正在接住。";fresh&&status=="waiting"->"下一步，\n我们一起决定。";fresh&&status=="running"->"$name 在忙，\n灵感也可以继续。";else->"今天，想一起\n做点什么？"}
 val subtitle=when{!vm.connected->"暂时离线，已有的对话仍在这里";status=="failed"&&fresh->"有一步需要看看，点开下方会话继续";status=="waiting"&&fresh->"有件事，正在等你的回应";else->"把想法交给 $name，让它慢慢成形。"}
 val density=LocalDensity.current
 val imeBottom=WindowInsets.ime.getBottom(density)
 val imeExtent=maxOf(WindowInsets.imeAnimationSource.getBottom(density),WindowInsets.imeAnimationTarget.getBottom(density),imeBottom)
 val imeProgress=if(imeExtent>0)(imeBottom.toFloat()/imeExtent).coerceIn(0f,1f) else 0f
 WashBackground(Modifier.fillMaxSize()){
 Column(Modifier.fillMaxSize()){
  Box(Modifier.fillMaxWidth().height(56.dp).padding(horizontal=16.dp)){
   Box(Modifier.align(Alignment.CenterStart)){RoundIcon(Icons.Outlined.Menu,"菜单",menu)}
   Text("Com!",Modifier.align(Alignment.Center),fontSize=Type.AppTitle,fontWeight=FontWeight.SemiBold,letterSpacing=(-.8).sp,color=Ink)
   Box(Modifier.align(Alignment.CenterEnd)){RoundIcon(Icons.Outlined.Tune,"新会话设置",advanced)}
  }
  BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()){
   // The available height already follows the system IME animation. Use it directly;
   // a second size animation would trail the keyboard and briefly crop the headline.
   val restingHeight=maxHeight+with(density){imeBottom.toDp()}
   val fontScale=density.fontScale
   val secondaryReveal=if(restingHeight>=440.dp*fontScale.coerceAtLeast(1f))1f-imeProgress else 0f
   val compression=maxOf(imeProgress,((350f-maxHeight.value/fontScale)/150f).coerceIn(0f,1f))
   val headingReveal=((maxHeight.value/fontScale-100f)/90f).coerceIn(0f,1f)
   val headingSize=(32f-10f*compression).sp
   val headingLineHeight=(41f-12f*compression).sp
   val headingBudget=((headingLineHeight.value*fontScale*2+12)*headingReveal).dp
   val secondaryBudget=(((if(focus!=null)84 else 0)+52+42*fontScale)*secondaryReveal).dp
   val restingSecondary=if(restingHeight>=440.dp*fontScale.coerceAtLeast(1f))((if(focus!=null)84 else 0)+52+42*fontScale).dp else 0.dp
   val restingHero=(restingHeight-(82*fontScale+12).dp-restingSecondary-78.dp).coerceIn(36.dp,270.dp)
   // Keep the avatar shrinking throughout keyboard entry even as secondary content
   // gives space back; otherwise it briefly grows before settling into typing mode.
   val typingHero=restingHero.coerceAtMost(104.dp)
   val preferredHero=restingHero+(typingHero-restingHero)*imeProgress
   val heroSize=(maxHeight-headingBudget-secondaryBudget-78.dp).coerceAtLeast(36.dp).coerceAtMost(preferredHero)
   Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal=24.dp,vertical=8.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.Center){
    CompanionWelcome(
     agent,title,subtitle,
     if(vm.voiceDelivery.isNotBlank())"thinking" else avatar,heroSize,
     headingSize,headingLineHeight,headingReveal,secondaryReveal,
    )
    Pill(listOf("Claude","Codex"),if(agent=="claude")0 else 1){select(if(it==0)"claude"else"codex")}
    Column(Modifier.homeReveal(secondaryReveal),horizontalAlignment=Alignment.CenterHorizontally){
    Spacer(Modifier.height(12.dp))
    if(focus!=null)Surface(modifier=Modifier.widthIn(max=450.dp).fillMaxWidth(),onClick={pick(focus)},enabled=secondaryReveal>.99f,shape=RoundedCornerShape(Radii.Xl),color=Card,border=BorderStroke(1.dp,Line),shadowElevation=0.dp){
     Row(Modifier.padding(horizontal=16.dp,vertical=14.dp),verticalAlignment=Alignment.CenterVertically){
      Box(Modifier.size(36.dp).clip(RoundedCornerShape(Radii.M)).background(if(status=="waiting")AmberBg else if(status=="running")EmberSoft else ChipBg),contentAlignment=Alignment.Center){
       if(status=="running")StatusDot(Ember,8.dp)
       else Icon(if(status=="waiting")Icons.Outlined.ChatBubbleOutline else Icons.Outlined.History,null,Modifier.size(18.dp),tint=if(status=="waiting")AmberText else Muted)
      }
      Column(Modifier.weight(1f).padding(horizontal=12.dp)){
       Text(focus.optString("display_title").ifBlank{"上次的对话"},fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=Ink,maxLines=1,overflow=TextOverflow.Ellipsis)
       Text(if(fresh)statusLabel(status)+" · "+relTime(focus.optDouble("updated"))else"已保存的对话",Modifier.padding(top=3.dp),fontSize=Type.Caption,color=Muted)
      }
      Icon(Icons.Outlined.ChevronRight,null,Modifier.size(20.dp),tint=Muted)
     }
    }
    Row(Modifier.padding(top=4.dp),horizontalArrangement=Arrangement.spacedBy(14.dp)){
     TextButton(onClick={vm.working=true;menu()},enabled=secondaryReveal>.99f){Icon(Icons.Outlined.Bolt,null,Modifier.size(15.dp));Text("工作中",Modifier.padding(start=5.dp),fontSize=Type.Caption)}
     TextButton(onClick={vm.working=false;menu()},enabled=secondaryReveal>.99f){Icon(Icons.Outlined.Forum,null,Modifier.size(15.dp));Text("全部对话",Modifier.padding(start=5.dp),fontSize=Type.Caption)}
    }
    }
   }
  }
 }
 }
}

@Composable private fun rememberCompanionState(key:String,status:String,connected:Boolean,hasApproval:Boolean=false):String{
 var previous by remember(key){mutableStateOf<String?>(null)}
 var visual by remember(key){mutableStateOf(companionVisualState(status,connected,hasApproval))}
 LaunchedEffect(key,status,connected,hasApproval){
  visual=companionVisualState(status,connected,hasApproval,previous)
  previous=if(connected)status else null
 }
 return visual
}

@Composable private fun CompanionWelcome(
 agent:String,heading:String,message:String,avatar:String,heroSize:Dp,
 headingSize:TextUnit,headingLineHeight:TextUnit,headingReveal:Float,messageReveal:Float,
){
 Column(horizontalAlignment=Alignment.CenterHorizontally){
  Box(Modifier.size(heroSize),contentAlignment=Alignment.Center){

   CompanionLanding(agent,avatar,Modifier.fillMaxSize())
  }
  Text(heading,Modifier.homeReveal(headingReveal).padding(bottom=12.dp),fontSize=headingSize,lineHeight=headingLineHeight,fontWeight=FontWeight.SemiBold,letterSpacing=(-.5).sp,color=Ink,textAlign=androidx.compose.ui.text.style.TextAlign.Center,maxLines=2,overflow=TextOverflow.Ellipsis)
  Text(message,Modifier.homeReveal(messageReveal).widthIn(max=360.dp).padding(bottom=12.dp),fontSize=Type.BodySm,lineHeight=21.sp,color=Muted,textAlign=androidx.compose.ui.text.style.TextAlign.Center,maxLines=2,overflow=TextOverflow.Ellipsis)
 }
}

/** Collapse in lockstep with system insets, without a competing animation clock. */
private fun Modifier.homeReveal(fraction:Float):Modifier=this
 .then(if(fraction<.01f)Modifier.clearAndSetSemantics{} else Modifier)
 .clipToBounds()
 .layout{measurable,constraints->
  val placeable=measurable.measure(constraints.copy(minHeight=0))
  layout(placeable.width,(placeable.height*fraction).roundToInt()){placeable.placeRelative(0,0)}
 }
 .graphicsLayer{alpha=fraction}

@OptIn(ExperimentalFoundationApi::class)
@Composable fun HistorySidebar(vm:WorkbenchModel,pick:(JSONObject)->Unit,new:()->Unit,settings:()->Unit){
 var search by rememberSaveable{mutableStateOf(vm.q.isNotBlank())};var filters by remember{mutableStateOf(false)};var menuItem by remember{mutableStateOf<JSONObject?>(null)}
 Column(Modifier.fillMaxSize().background(SidebarBg).padding(horizontal=12.dp)){
  Row(Modifier.fillMaxWidth().padding(top=8.dp,bottom=8.dp),verticalAlignment=Alignment.CenterVertically){
   TextButton(onClick=new){Icon(Icons.Outlined.Edit,null,Modifier.size(20.dp));Text("新聊天",Modifier.padding(start=9.dp),fontSize=Type.Body,fontWeight=FontWeight.Medium,color=Ink)};Spacer(Modifier.weight(1f))
   IconButton(onClick={vm.run{vm.store.request("/refresh",JSONObject());vm.refresh()}},modifier=Modifier.size(38.dp)){Icon(Icons.Outlined.Refresh,"刷新历史",Modifier.size(19.dp),tint=Muted)}
   IconButton(onClick={search=!search},modifier=Modifier.size(38.dp)){Icon(Icons.Outlined.Search,"搜索",Modifier.size(21.dp),tint=Ink)}
  }
  if(search){Surface(Modifier.fillMaxWidth().padding(bottom=8.dp),shape=RoundedCornerShape(Radii.Sheet),color=Track){
   Row(Modifier.padding(horizontal=14.dp),verticalAlignment=Alignment.CenterVertically){
    Icon(Icons.Outlined.Search,null,Modifier.size(17.dp),tint=Faint)
    BasicTextField(vm.q,{vm.q=it;vm.working=false},Modifier.weight(1f).padding(vertical=11.dp).padding(start=9.dp),textStyle=TextStyle(fontSize=Type.BodySm,color=Ink),singleLine=true,cursorBrush=SolidColor(Ink),decorationBox={inner->Box{if(vm.q.isBlank())Text("搜索聊天内容",fontSize=Type.BodySm,color=Faint);inner()}})
    if(vm.q.isNotBlank())IconButton(onClick={vm.q=""},modifier=Modifier.size(30.dp)){Icon(Icons.Outlined.Close,"清空",Modifier.size(15.dp),tint=Muted)}
   }
  }}
  SidebarEntry(Icons.Outlined.Bolt,"工作中",vm.working){vm.working=true}
  SidebarEntry(Icons.Outlined.Forum,"所有会话",!vm.working){vm.working=false}
  SidebarEntry(Icons.Outlined.FolderOpen,"工作目录与筛选",filters){filters=!filters}
  AnimatedVisibility(filters){Column(Modifier.padding(start=4.dp)){
   Choice(vm.agent.ifBlank{"全部 Agent"},listOf("全部 Agent","Claude","Codex","Pi")){vm.agent=if(it=="全部 Agent")"" else if(it=="Claude")"claude"else it.lowercase()}
   Choice(vm.cwd.shortPath().ifBlank{"所有目录"},listOf("所有目录")+vm.store.cached("list.json").array("sessions").map{it.optString("cwd")}.filter{it.isNotBlank()}.distinct()){vm.cwd=if(it=="所有目录")"" else it}
   Choice(if(vm.days==0)"所有时间" else "最近${vm.days}天",listOf("所有时间","最近7天","最近30天","最近90天")){vm.days=it.filter(Char::isDigit).toIntOrNull()?:0}
   Choice(if(vm.archived)"已归档" else "未归档",listOf("未归档","已归档")){vm.archived=it=="已归档"}
  }}
  if(search&&vm.q.isNotBlank()){
   Row(Modifier.horizontalScroll(rememberScrollState())){listOf("" to "全部","user" to "提问","assistant" to "回复","tool" to "执行").forEach{(key,label)->TextButton(onClick={vm.role=key}){Text(label,color=if(vm.role==key)Ink else Muted,fontWeight=if(vm.role==key)FontWeight.Bold else FontWeight.Normal)}}}
   Choice(if(vm.sort=="relevance")"按相关性" else "按时间",listOf("按相关性","按时间")){vm.sort=if(it=="按相关性")"relevance" else "recent"}
  }
  val rows=vm.rows.filter{!vm.working||it.optBoolean("managed")&&it.optString("status")!="ended"}.let{if(vm.working)it.sortedByDescending{s->s.optString("status")=="waiting"}else it}
  val groups=remember(rows,vm.q){if(vm.q.isNotBlank())listOf("搜索结果 · ${rows.size}" to rows)else rows.groupBy{dayLabel(it.optDouble("updated"))}.toList()}
  LazyColumn(Modifier.weight(1f),contentPadding=PaddingValues(bottom=16.dp)){
   groups.forEach{(label,list)->
    item(key="g:$label"){SectionHeader(label,Modifier.padding(start=10.dp,top=16.dp,bottom=6.dp))}
    items(list,key={it.getString("id")}){s->
     val selBg by animateColorAsState(if(vm.selected==s.getString("id"))AccentSoft else Color.Transparent,Motion.Tint,label="行选中")
     val (rowPress,rowMotion)=rememberPress(.98f)
     Column(Modifier.fillMaxWidth().then(rowMotion).clip(RoundedCornerShape(Radii.M)).background(selBg).combinedClickable(interactionSource=rowPress,indication=null,onClick={pick(s)},onLongClick={menuItem=s}).padding(horizontal=12.dp,vertical=12.dp)){
      Row(verticalAlignment=Alignment.CenterVertically){
       Text(s.optString("display_title").ifBlank{"新聊天"},fontSize=Type.Body,fontWeight=FontWeight.Medium,color=Ink,maxLines=1,overflow=TextOverflow.Ellipsis,modifier=Modifier.weight(1f))
       Text(relTime(s.optDouble("updated")),Modifier.padding(start=8.dp),fontSize=Type.Caption,color=Faint)
       if(s.optInt("pinned")==1)Icon(Icons.Outlined.PushPin,null,Modifier.padding(start=4.dp).size(12.dp),tint=Faint)
       if(s.optString("status")=="running")Box(Modifier.padding(start=6.dp)){StatusDot(Ink,5.dp)}
      }
      if(vm.q.isNotBlank()&&s.optString("snippet").isNotBlank()){Text(highlight(s.optString("snippet"),vm.q),Modifier.padding(top=7.dp),fontSize=Type.Caption,maxLines=3,overflow=TextOverflow.Ellipsis);Text("${s.optString("agent")} · 命中 ${s.optInt("hit_count")} 处",Modifier.padding(top=6.dp),fontSize=Type.Micro,color=Faint)}
      else if(s.optString("status")=="waiting")Row(Modifier.padding(top=6.dp),verticalAlignment=Alignment.CenterVertically){StatusDot(AmberText,6.dp);Text("需要你回应",Modifier.padding(start=7.dp),fontSize=Type.Caption,color=AmberText)}
     }
    }
   }
   if(rows.isEmpty())item{
    if(vm.busy&&vm.q.isBlank())Column(Modifier.padding(horizontal=4.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){repeat(3){ShimmerCard(Modifier.fillMaxWidth())}}
    else if(vm.q.isNotBlank())EmptyState(Icons.Outlined.Search,"没有找到匹配内容","换个关键词，或调整筛选条件试试")
    else EmptyState(Icons.Outlined.Forum,"这里会保存你的聊天","开启新的会话后，它会自动出现在这里")
   }
   item{Text(if(!vm.connected)"离线：仅搜索已缓存内容" else if(vm.index.optBoolean("scanning"))"正在索引 ${vm.index.optInt("done")}/${vm.index.optInt("total")}" else "${vm.index.optInt("total")} 段 Mac mini 历史"+(if(vm.index.optInt("unreadable")>0)" · ${vm.index.optInt("unreadable")} 份不可读" else ""),Modifier.padding(12.dp),fontSize=Type.Micro,color=Faint)}
  }
  HorizontalDivider(color=Line)
  Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radii.M)).clickable(onClick=settings).padding(horizontal=8.dp,vertical=12.dp),verticalAlignment=Alignment.CenterVertically){Box(Modifier.size(32.dp).background(Ink,CircleShape),contentAlignment=Alignment.Center){Text("E",color=Color.White,fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold)};Column(Modifier.weight(1f).padding(start=11.dp)){Text("Eddie",fontSize=Type.BodySm,fontWeight=FontWeight.Medium);Text(if(vm.connected)"Mac mini · 已连接" else "连接与设置",fontSize=Type.Caption,color=Muted)};Icon(Icons.Outlined.MoreHoriz,"账户与连接设置",tint=Muted)}
 }
 menuItem?.let{SessionMenu(vm,it){menuItem=null}}
}
@Composable fun SidebarEntry(icon:androidx.compose.ui.graphics.vector.ImageVector,text:String,selected:Boolean,click:()->Unit){
 val tint=if(selected)Ink else Muted
 Row(Modifier.fillMaxWidth().height(44.dp).clip(RoundedCornerShape(Radii.M)).background(if(selected)AccentSoft else Color.Transparent).clickable(onClick=click).padding(horizontal=12.dp),verticalAlignment=Alignment.CenterVertically){Icon(icon,null,Modifier.size(20.dp),tint=tint);Text(text,Modifier.padding(start=12.dp),fontSize=14.5.sp,fontWeight=if(selected)FontWeight.Medium else FontWeight.Normal,color=tint)}
}

@Composable fun Composer(text:String,change:(String)->Unit,placeholder:String,enabled:Boolean,running:Boolean,more:()->Unit,send:()->Unit,stop:()->Unit,voice:(()->Unit)?=null,modelConfigured:Boolean=false,motion:MessageSendMotionState?=null,readOnly:Boolean=false){
 var focused by remember{mutableStateOf(false)}
 val line by animateColorAsState(if(focused)Muted.copy(alpha=.2f) else Color.Transparent,Motion.Tint,label="输入框描边")
 val haptics=rememberComHaptics()
 var editing by remember{mutableStateOf(TextFieldValue(text,TextRange(text.length)))}
 LaunchedEffect(text){if(editing.text!=text)editing=TextFieldValue(text,TextRange(text.length))}
 val newline:()->Unit={val start=editing.selection.min;val next=editing.text.replaceRange(start,editing.selection.max,"\n");editing=TextFieldValue(next,TextRange(start+1));change(next)}
 val canSend=enabled&&text.isNotBlank()
 val style=TextStyle(fontSize=Type.Body,color=Ink,lineHeight=22.sp)
 Surface(Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=8.dp).testTag("work-composer-surface"),shape=RoundedCornerShape(32.dp),color=UserBubble,border=BorderStroke(1.dp,line),shadowElevation=0.dp){
  Row(Modifier.padding(horizontal=6.dp,vertical=5.dp),verticalAlignment=Alignment.CenterVertically){
   IconButton(onClick={haptics(HapticCue.Selection);more()},enabled=!readOnly,modifier=Modifier.size(42.dp)){Icon(Icons.Outlined.Add,if(modelConfigured)"模型与推理 · 已自定义" else "选择模型与推理",Modifier.size(24.dp),tint=if(modelConfigured)EmberDeep else Ink)}
   BasicTextField(editing,{editing=it;change(it.text)},Modifier.weight(1f).heightIn(min=42.dp,max=128.dp).messageSendComposerBounds(motion,background=true,backgroundColor=UserBubble).padding(vertical=10.dp,horizontal=5.dp).onFocusChanged{focused=it.isFocused}.testTag("work-composer").messageSendComposerBounds(motion),readOnly=readOnly,textStyle=style,keyboardOptions=KeyboardOptions(imeAction=ImeAction.Send),keyboardActions=KeyboardActions(onSend={if(canSend)send()}),onTextLayout={motion?.updateComposerLayout(it,style,backgroundColor=UserBubble)},cursorBrush=SolidColor(Ink),decorationBox={inner->Box{if(text.isBlank())Text(placeholder,style=style.copy(color=Faint),maxLines=1);inner()}})
   if(text.isNotBlank()&&!readOnly)IconButton(onClick=newline,modifier=Modifier.size(36.dp)){Icon(Icons.Outlined.KeyboardReturn,"插入换行",Modifier.size(19.dp),tint=Muted)}
   val (press,pressMod)=rememberPress(.97f)
   if(canSend)IconButton(onClick={haptics(HapticCue.Commit);send()},modifier=Modifier.size(42.dp).then(pressMod).clip(CircleShape).background(Ink),interactionSource=press){Icon(Icons.Outlined.ArrowUpward,"发送",tint=Color.White,modifier=Modifier.size(21.dp))}
   else if(running)IconButton(onClick={haptics(HapticCue.RecordingStop);stop()},enabled=enabled,modifier=Modifier.size(42.dp).then(pressMod).clip(CircleShape).background(Ink),interactionSource=press){Icon(Icons.Outlined.Stop,"停止当前执行",tint=Color.White,modifier=Modifier.size(20.dp))}
   else if(voice!=null)IconButton(onClick=voice,enabled=!readOnly,modifier=Modifier.size(42.dp).then(pressMod),interactionSource=press){Icon(Icons.Outlined.MicNone,"快速语音 · Pi",Modifier.size(23.dp),tint=Muted)}
  }
 }
}

@Composable fun ChatPage(vm:WorkbenchModel,menu:()->Unit,new:()->Unit,snapshot:ConversationSnapshot,terminal:Boolean,setTerminal:(Boolean)->Unit,active:Boolean=true,motion:MessageSendMotionState?=null){
 val sid=snapshot.sid;val s=snapshot.detail.optJSONObject("session")?:JSONObject();val caps=s.optJSONObject("capabilities")?:JSONObject()
 var showMenu by remember{mutableStateOf(false)};var options by remember{mutableStateOf(false)};var search by rememberSaveable(sid){mutableStateOf(vm.queryInSession.isNotBlank())};var matchIndex by rememberSaveable(sid){mutableIntStateOf(0)}
 val nativeMessages=remember(snapshot.detail,snapshot.live){val merged=linkedMapOf<String,JSONObject>();snapshot.detail.array("messages").forEach{merged[it.optString("id")]=it};snapshot.live.array("items").forEach{merged[it.optString("id")]=it};val seed=merged["accepted-first-message"];if(seed!=null&&merged.values.any{it.optString("id")!="accepted-first-message"&&it.optString("role")=="user"&&it.optString("text")==seed.optString("text")})merged.remove("accepted-first-message");merged.values.toList()}
 val outgoing=vm.outgoingMessages.filter{it.scope==sid}
 val messages=remember(nativeMessages,outgoing){mergeOutgoingMessages(nativeMessages,outgoing)}
 val displayRows=remember(messages){transcriptRows(messages.map{it.optString("role")},messages.map{messageMotionId(it)})}
 val rowById=remember(displayRows,messages){val m=HashMap<String,Int>();displayRows.forEachIndexed{i,row->row.indices.forEach{j->m.putIfAbsent(messages[j].optString("id"),i)}};m}
 fun rowFor(id:String)=rowById[id]?:0
 val list=rememberLazyListState();val scope=rememberCoroutineScope();val following by remember{derivedStateOf{!list.canScrollForward}}
 val sendRow=motion?.messageId?.let{id->displayRows.indexOfFirst{row->row.indices.any{messageMotionId(messages[it])==id}}.takeIf{it>=0}}
 MessageSendListScroll(motion,list,sendRow,active)
 MessageViewportAnchor(list,sid,active,motion)
 val status=snapshot.live.optString("status",s.optString("status"))
 val sessionFresh=vm.connected&&snapshot.fresh
 val companion=rememberCompanionState(sid,status,sessionFresh&&caps.optBoolean("input"),snapshot.live.array("approvals").isNotEmpty())
 val matches=remember(messages,vm.queryInSession){val q=vm.queryInSession;if(q.isBlank())emptyList() else{val terms=q.trim().split(whitespace);messages.filter{m->val hay=m.optString("text")+m.optString("title");terms.all{hay.contains(it,true)}}}}
 LaunchedEffect(sid,active){if(!active)return@LaunchedEffect;val idx=vm.store.prefs.getInt("scroll:$sid",0);list.scrollToItem(idx.coerceAtMost(displayRows.size))}
 val restingIndex=remember(sid){intArrayOf(-1)}
 LaunchedEffect(sid,list,active){if(!active)return@LaunchedEffect;snapshotFlow{list.firstVisibleItemIndex}.distinctUntilChanged().collectLatest{restingIndex[0]=it;delay(500);vm.store.prefs.edit().putInt("scroll:$sid",it).apply()}}
 DisposableEffect(sid){onDispose{if(restingIndex[0]>=0)vm.store.prefs.edit().putInt("scroll:$sid",restingIndex[0]).apply()}}
 LaunchedEffect(active,vm.targetMessage,messages.size){if(active&&vm.targetMessage.isNotBlank()){val i=messages.indexOfFirst{it.optString("id")==vm.targetMessage};if(i>=0){list.scrollToItem(rowFor(vm.targetMessage));vm.targetMessage=""}}}
 val tail=messages.lastOrNull()
 LaunchedEffect(active,messages.size,tail?.optString("id"),tail?.optString("status"),tail?.optString("text")?.length){if(active&&following&&vm.queryInSession.isBlank()&&motion?.messageId==null)list.animateScrollToItem(displayRows.size)}
 Column(Modifier.fillMaxSize()){
  Box(Modifier.fillMaxWidth().height(if(terminal)74.dp else 126.dp).padding(horizontal=16.dp,vertical=8.dp).testTag("work-session-header")){
   Box(Modifier.align(Alignment.TopStart)){RoundIcon(Icons.Outlined.ArrowBack,"返回首页",new)}
   Column(Modifier.align(Alignment.TopCenter).widthIn(max=280.dp).fillMaxWidth(.64f),horizontalAlignment=Alignment.CenterHorizontally){
    if(!terminal)CompanionLanding(s.optString("agent","pi"),companion,Modifier.size(68.dp),interactive=false)
    Surface(onClick={showMenu=true},shape=RoundedCornerShape(Radii.Xl),color=Card,border=BorderStroke(1.dp,Line),shadowElevation=Elev.Card){
     Row(Modifier.padding(horizontal=12.dp,vertical=6.dp),verticalAlignment=Alignment.CenterVertically){Text(s.optString("display_title","正在读取…"),Modifier.weight(1f,fill=false),fontSize=Type.Caption,fontWeight=FontWeight.Medium,color=Ink,maxLines=1,overflow=TextOverflow.Ellipsis);Icon(Icons.Outlined.ChevronRight,null,Modifier.padding(start=3.dp).size(14.dp),tint=Muted)}
    }
    if(!terminal)Text(if(!vm.connected)"离线记录"else if(!caps.optBoolean("input"))"只读历史"else if(sessionFresh)statusLabel(status)else"正在同步",Modifier.padding(top=4.dp),fontSize=Type.Micro,color=Muted)
   }
   Column(Modifier.align(Alignment.TopEnd),horizontalAlignment=Alignment.CenterHorizontally){
    RoundIcon(if(terminal)Icons.Outlined.ChatBubbleOutline else Icons.Outlined.DesktopWindows,if(terminal)"返回对话"else"打开终端"){if(terminal||caps.optBoolean("terminal")&&vm.connected){motion?.cancel();setTerminal(!terminal)}}
    if(!terminal)IconButton(onClick={search=!search},modifier=Modifier.size(36.dp).padding(top=3.dp)){Icon(Icons.Outlined.Search,"查找本会话",Modifier.size(19.dp),tint=Muted)}
   }
  }
  if(search)Row(Modifier.padding(horizontal=16.dp),verticalAlignment=Alignment.CenterVertically){OutlinedTextField(vm.queryInSession,{vm.queryInSession=it;matchIndex=0},Modifier.weight(1f),placeholder={Text("查找内容",fontSize=Type.BodySm)},singleLine=true,shape=RoundedCornerShape(Radii.Xxl));Text("${if(matches.isEmpty())0 else matchIndex+1}/${matches.size}",Modifier.padding(5.dp),fontSize=Type.Micro,color=Muted);listOf(-1 to Icons.Outlined.KeyboardArrowUp,1 to Icons.Outlined.KeyboardArrowDown).forEach{(delta,icon)->IconButton(enabled=matches.isNotEmpty(),onClick={matchIndex=(matchIndex+delta+matches.size)%matches.size;scope.launch{list.animateScrollToItem(rowFor(matches[matchIndex].optString("id")))}}){Icon(icon,if(delta<0)"上一个命中"else"下一个命中")}}}
  if(terminal&&caps.optBoolean("terminal"))Box(Modifier.weight(1f).fillMaxWidth()){Terminal(vm,sid)}
  else Box(Modifier.weight(1f).fillMaxWidth().testTag("work-message-viewport")){
   LazyColumn(state=list,modifier=Modifier.testTag("work-message-list"),contentPadding=PaddingValues(horizontal=20.dp,vertical=22.dp)){
    items(displayRows,key={it.key}){row->
     MessageSendRow(motion,row.key,trailingSpacing=26.dp){
      if(row.process)ProcessGroup(row.indices.map{messages[it]},vm.queryInSession,vm.font,status=="running"&&row==displayRows.last())
      else{
       val message=messages[row.indices.first()]
       MessageSwipeActions(message,enabled=active&&!message.optBoolean("local"),onReply={vm.workReferences[sid]=messageReference(it,"reply",s.optString("agent","pi").replaceFirstChar{c->c.uppercase()},sid)},onForward={vm.workReferences[sid]=messageReference(it,"forward",s.optString("agent","pi").replaceFirstChar{c->c.uppercase()},sid)}){
        Message(message,vm.queryInSession,vm.font,s.optString("agent","pi"),motion,active)
       }
      }
     }
    }
    item{
     if(status=="running")Row(verticalAlignment=Alignment.CenterVertically){ThinkingDots();Text("正在处理",Modifier.padding(start=10.dp),fontSize=Type.BodySm,color=Muted)}
     else if(status=="waiting")Row(verticalAlignment=Alignment.CenterVertically){Box(Modifier.size(6.dp).background(AmberText,CircleShape));Text("等待你的回应",Modifier.padding(start=8.dp),fontSize=Type.BodySm,color=AmberText)}
     if(!caps.optBoolean("input"))Text(s.optString("coverage","读取历史不会启动 Agent"),fontSize=Type.Caption,color=Faint)
     if(caps.optBoolean("input")&&messages.isEmpty())Text("发送第一句话开始。执行过程会实时显示；首条消息后可切换终端。",fontSize=Type.BodySm,color=Muted)
    }
   }
   if(!following)Surface(onClick={scope.launch{list.animateScrollToItem(displayRows.size)}},modifier=Modifier.align(Alignment.BottomCenter).padding(bottom=10.dp),shape=CircleShape,color=UserBubble,shadowElevation=0.dp){Icon(Icons.Outlined.ArrowDownward,"回到最新",Modifier.padding(8.dp).size(17.dp),tint=Ink)}
  }
  if(!terminal){
   snapshot.live.array("approvals").forEach{Approval(vm,it)}
   if(!vm.connected)Text("连接中断 · 远端任务不会因此停止",Modifier.padding(horizontal=22.dp),fontSize=Type.Caption,color=Muted)
   if(!caps.optBoolean("input"))Column(Modifier.padding(horizontal=20.dp,vertical=12.dp)){
    Button(onClick={vm.resume()},enabled=vm.connected&&!vm.busy&&caps.optBoolean("resume"),shape=RoundedCornerShape(Radii.Xxl),modifier=Modifier.fillMaxWidth().height(50.dp)){Text(if(caps.optBoolean("restart_for_identity"))"升级并恢复会话"else"继续这个会话",fontSize=Type.Body,fontWeight=FontWeight.Medium)}
    if(caps.optBoolean("restart_for_identity"))Text("重启空闲 Pi 进程，保留对话历史与草稿",Modifier.padding(top=8.dp),fontSize=Type.Caption,color=Muted)
    if(!caps.optBoolean("resume"))Text("只读历史 · 正在使用或状态未确认",Modifier.padding(top=8.dp),fontSize=Type.Caption,color=Faint)
   }
  }
 }
 if(showMenu)SessionMenu(vm,s){showMenu=false}
 if(options)AlertDialog(onDismissRequest={options=false},containerColor=Card,title={Text("会话选项",fontWeight=FontWeight.SemiBold)},text={Column{TextButton(onClick={options=false;setTerminal(true)},enabled=caps.optBoolean("terminal")){Icon(Icons.Outlined.Terminal,null);Text("打开完整终端",Modifier.padding(start=12.dp))};TextButton(onClick={options=false;showMenu=true}){Icon(Icons.Outlined.Tune,null);Text("会话详情与管理",Modifier.padding(start=12.dp))}}},confirmButton={TextButton(onClick={options=false}){Text("完成")}})
}

@Composable fun ProcessGroup(messages:List<JSONObject>,q:String,font:Float,running:Boolean){
 var expanded by rememberSaveable(messages.first().optString("id")){mutableStateOf(false)}
 val hasHit=q.isNotBlank()&&messages.any{m->val hay=m.optString("text")+m.optString("title");q.trim().split(whitespace).all{hay.contains(it,true)}}
 Column(Modifier.fillMaxWidth()){
  Row(Modifier.fillMaxWidth().heightIn(min=44.dp).clip(RoundedCornerShape(Radii.M)).clickable{expanded=!expanded}.padding(vertical=6.dp),verticalAlignment=Alignment.CenterVertically){
   Box(Modifier.size(26.dp).clip(RoundedCornerShape(Radii.S)).background(ToolSurface).border(1.dp,Line,RoundedCornerShape(Radii.S)),contentAlignment=Alignment.Center){
    if(running)StatusDot(Ink,7.dp) else Icon(Icons.Outlined.Check,null,Modifier.size(14.dp),tint=Muted)
   }
   Text(if(running)"正在处理" else "处理过程",Modifier.padding(start=10.dp),fontSize=13.5.sp,fontWeight=FontWeight.Medium,color=Ink)
   Surface(Modifier.padding(start=8.dp),shape=RoundedCornerShape(50),color=ChipBg){Text("${messages.size}",Modifier.padding(horizontal=8.dp,vertical=2.dp),fontSize=Type.Caption,color=Muted)}
   Spacer(Modifier.weight(1f))
   val chevron by animateFloatAsState(if(expanded||hasHit)0f else -90f,Motion.Gentle,label="过程箭头")
   Icon(Icons.Outlined.ExpandMore,if(expanded)"收起处理过程" else "展开处理过程",Modifier.size(20.dp).rotate(chevron),tint=Faint)
  }
  AnimatedVisibility(expanded||hasHit,enter=expandVertically(animationSpec=spring(dampingRatio=.88f,stiffness=Spring.StiffnessMediumLow))+fadeIn(tween(160)),exit=shrinkVertically(animationSpec=spring(dampingRatio=1f,stiffness=Spring.StiffnessMedium))+fadeOut(tween(100))){Column(Modifier.padding(start=36.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
   messages.forEach{m->Message(m,q,font)}
  }}
 }
}

@Composable fun Message(m:JSONObject,q:String,font:Float,agent:String="pi",motion:MessageSendMotionState?=null,measureMotion:Boolean=true){
 val motionId=messageMotionId(m)
 val style=TextStyle(fontSize=font.sp,lineHeight=(font+8).sp,color=Ink)
 val plain=classifyMessageSendTransition(m.optString("text"),1,1)==MessageSendTransitionKind.Morph
 val bubbleColor=if(m.optString("role")=="user")HermesUserBubble else HermesAssistantBubble
 val target=if(motion!=null)Modifier.messageSendMotionTarget(motion,motionId).then(if(measureMotion)Modifier.messageSendTargetBounds(motion,motionId)else Modifier).onGloballyPositioned{if(measureMotion&&(!plain||m.optJSONObject("reference")!=null))motion.updateTargetContent(motionId,MessageSendContentKind.RichText)}else Modifier
 val role=m.optString("role");val tool=role in listOf("tool","progress");val body=m.optString("text");var expanded by rememberSaveable(m.optString("id")){mutableStateOf(false)};val context=LocalContext.current
 if(tool){
  Column(Modifier.fillMaxWidth()){
   Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radii.S)).clickable{expanded=!expanded}.padding(vertical=7.dp),verticalAlignment=Alignment.CenterVertically){
    if(m.optString("state")=="running")StatusDot(Ink,7.dp) else Icon(Icons.Outlined.Check,null,Modifier.size(15.dp),tint=Faint)
    Text(m.optString("title").ifBlank{"执行记录"}.take(120),Modifier.weight(1f).padding(start=9.dp),fontSize=12.5.sp,color=Muted,maxLines=2,overflow=TextOverflow.Ellipsis)
    val chevron by animateFloatAsState(if(expanded)0f else -90f,Motion.Gentle,label="记录箭头")
    Icon(Icons.Outlined.ExpandMore,if(expanded)"收起" else "展开执行记录",Modifier.size(16.dp).rotate(chevron),tint=Faint)
   }
   AnimatedVisibility(expanded||q.isNotBlank(),enter=expandVertically(animationSpec=spring(dampingRatio=.9f,stiffness=Spring.StiffnessMedium))+fadeIn(tween(150)),exit=shrinkVertically(animationSpec=spring(dampingRatio=1f,stiffness=Spring.StiffnessMedium))+fadeOut(tween(100))){Surface(color=ToolSurface,shape=RoundedCornerShape(Radii.M),border=BorderStroke(1.dp,Line)){SelectionContainer{Text(highlight(body,q),Modifier.padding(13.dp),fontFamily=FontFamily.Monospace,fontSize=(font-3).sp,lineHeight=(font+5).sp,color=Ink)}}}
  }
 }else{
  Column(Modifier.fillMaxWidth(),horizontalAlignment=if(role=="user")Alignment.End else Alignment.Start){
   Surface(target.widthIn(max=680.dp).fillMaxWidth(if(role=="user").88f else .96f),color=bubbleColor,shape=RoundedCornerShape(28.dp),shadowElevation=0.dp){
    Column{
    m.optJSONObject("reference")?.let{reference->Text("${if(reference.optString("mode")=="forward")"引用"else"回复"} · ${reference.optString("author")}\n${reference.optString("text")}",Modifier.padding(horizontal=16.dp,vertical=10.dp),fontSize=Type.Caption,lineHeight=17.sp,color=Muted,maxLines=3,overflow=TextOverflow.Ellipsis)}
    if(q.isNotBlank()||role=="user"&&plain)SelectionContainer{Text(if(q.isNotBlank())highlight(body,q)else androidx.compose.ui.text.AnnotatedString(body),Modifier.padding(horizontal=16.dp,vertical=12.dp).then(if(measureMotion)Modifier.messageSendTargetBounds(motion,motionId,text=true)else Modifier),style=style,onTextLayout={if(measureMotion)motion?.updateTargetLayout(motionId,it,style,bubbleColor,if(m.optJSONObject("reference")!=null)MessageSendContentKind.RichText else MessageSendContentKind.Text)})}
    else MarkdownMessage(body,font,padding=14)
    }
   }
   if(role=="user")Text(when(m.optString("status",m.optString("delivery_status"))){"sending"->"发送中";"unknown"->"发送结果待核实";"failed"->"发送失败";else->"已发送"},Modifier.messageSendMetadata(motion,motionId).padding(top=4.dp,end=8.dp),fontSize=Type.Caption,color=Faint)
   if(role=="assistant")Row(Modifier.messageSendMetadata(motion,motionId).padding(top=4.dp)){
    IconButton(onClick={(context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager).setPrimaryClip(ClipData.newPlainText("回复",body))},modifier=Modifier.size(32.dp)){Icon(Icons.Outlined.ContentCopy,"复制回复",Modifier.size(15.dp),tint=Faint)}
    IconButton(onClick={context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT,body),"分享回复"))},modifier=Modifier.size(32.dp)){Icon(Icons.Outlined.IosShare,"分享回复",Modifier.size(16.dp),tint=Faint)}
   }
  }
 }
}
