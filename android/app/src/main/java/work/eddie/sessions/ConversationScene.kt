package work.eddie.sessions

import android.content.Intent
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.*
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.*
import org.json.JSONObject
import org.json.JSONArray
import java.util.UUID

private data class CompanionAnchor(val rect:Rect,val clip:Rect,val agent:String,val state:String,val interactive:Boolean)
private class CompanionStage {
 val anchors=mutableStateMapOf<String,CompanionAnchor>()
}
private val LocalCompanionStage=staticCompositionLocalOf<CompanionStage?>{null}
private val LocalSceneKey=staticCompositionLocalOf{"home"}

/** A measured landing point; the actual mascot stays alive above the scene. */
@Composable fun CompanionLanding(agent:String,state:String,modifier:Modifier,interactive:Boolean=true){
 val stage=LocalCompanionStage.current
 val key=LocalSceneKey.current
 if(stage==null){CompanionAvatar(agent,state,modifier,interactive);return}
 var rect by remember{mutableStateOf<Rect?>(null)}
 var clip by remember{mutableStateOf(Rect.Zero)}
 Box(modifier.onGloballyPositioned{rect=Rect(it.positionInRoot(),androidx.compose.ui.geometry.Size(it.size.width.toFloat(),it.size.height.toFloat()));clip=it.boundsInRoot()})
 val measured=rect
 val visibleBounds=clip
 SideEffect{measured?.let{stage.anchors[key]=CompanionAnchor(it,visibleBounds,agent,state,interactive)}}
 DisposableEffect(key){onDispose{stage.anchors.remove(key)}}
}

data class ConversationSnapshot(val sid:String,val detail:JSONObject,val live:JSONObject,val fresh:Boolean)

/** One input surface and one mascot survive navigation, including interrupted transitions. */
@Composable fun ConversationScene(
 vm:WorkbenchModel,agent:String,select:(String)->Unit,menu:()->Unit,
 advanced:()->Unit,pick:(JSONObject)->Unit,new:()->Unit,
){
 val context=LocalContext.current
 val stage=remember{CompanionStage()}
 val motion=LocalMessageSendMotion.current?:rememberMessageSendMotionState(vm.active)
 val creating=vm.creatingMessage
 val route=vm.selected.ifBlank{creating?.scope?:"home"}
 val home=route=="home"
 var prompt by rememberSaveable{mutableStateOf(vm.store.prefs.getString("new-draft","")?:"")}
 var modelPicker by remember{mutableStateOf(false)}
 var terminal by rememberSaveable(vm.selected){mutableStateOf(false)}
 val session=vm.detail.optJSONObject("session")?:JSONObject()
 val pickerAgent=if(home)agent else if(creating!=null)vm.creatingAgent else session.optString("agent",agent)
 val pickerSid=if(home)"" else route
 val modelSelection=vm.selection(pickerAgent,pickerSid)
 val caps=session.optJSONObject("capabilities")?:JSONObject()
 val status=vm.live.optString("status",session.optString("status"))
 var origin by remember{mutableStateOf(Offset.Zero)}
 var lastAnchor by remember{mutableStateOf<CompanionAnchor?>(null)}
 val routeAnchor=stage.anchors[route]
 val anchor=routeAnchor?:lastAnchor
 SideEffect{stage.anchors[route]?.let{lastAnchor=it}}
 val voice:()->Unit={context.startActivity(Intent(context,QuickVoiceActivity::class.java))}
 Box(Modifier.fillMaxSize()){
 Column(Modifier.fillMaxSize()){
  Box(Modifier.weight(1f).fillMaxWidth().clipToBounds().onGloballyPositioned{origin=it.positionInRoot()}){
   CompositionLocalProvider(LocalCompanionStage provides stage){
    AnimatedContent(route,modifier=Modifier.fillMaxSize(),transitionSpec={
     (fadeIn(tween(180))+slideInVertically(tween(220,easing=Motion.TravelEasing)){if(targetState=="home")-it/50 else it/50}) togetherWith
      fadeOut(tween(100)) using SizeTransform(clip=false)
    },label="连续会话场景"){scene->
     CompositionLocalProvider(LocalSceneKey provides scene){
      Box(Modifier.fillMaxSize().then(if(scene!=route)Modifier.clearAndSetSemantics{} else Modifier)){
      if(scene=="home")NewChatHome(vm,agent,select,menu,advanced,pick)
      else{
       var snapshot by remember(scene){mutableStateOf(ConversationSnapshot(scene,vm.detail,vm.live,vm.liveFresh&&vm.liveSessionId==scene))}
       val current=if(vm.selected==scene)ConversationSnapshot(scene,vm.detail,vm.live,vm.liveFresh&&vm.liveSessionId==scene) else snapshot
       SideEffect{if(vm.selected==scene)snapshot=current}
       val pending=creating?.takeIf{it.scope==scene}
       val displayed=if(pending==null)current else ConversationSnapshot(scene,JSONObject().put("session",JSONObject().put("agent",vm.creatingAgent).put("display_title",pending.text.take(60)).put("status","ready").put("capabilities",JSONObject().put("input",true))).put("messages",JSONArray(mergeOutgoingMessages(emptyList(),listOf(pending)))),JSONObject(),true)
       ChatPage(vm,menu,new,displayed,terminal,{terminal=it},scene==route,motion)
      }
      if(scene!=route)Box(Modifier.matchParentSize().pointerInput(Unit){awaitPointerEventScope{while(true){awaitPointerEvent().changes.forEach{it.consume()}}}})
      }
     }
    }
   }
   anchor?.let{target->
    val travel=remember{Animatable(target.rect,Rect.VectorConverter)}
    var settledRoute by remember{mutableStateOf(route)}
    var requestedRoute by remember{mutableStateOf(route)}
    var travelling by remember{mutableStateOf(false)}
    LaunchedEffect(route,routeAnchor?.rect){
     if(requestedRoute!=route){requestedRoute=route;travelling=true}
     // Keep the existing face in place until the destination has actually laid
     // out. A fallback anchor must never mark a new route as already settled.
     val destination=routeAnchor?.rect?:return@LaunchedEffect
     if(travelling){
      travel.animateTo(destination,spring(dampingRatio=1f,stiffness=520f))
      settledRoute=route;travelling=false
     }else travel.snapTo(destination)
    }
    val bounds=travel.value
    val alpha by animateFloatAsState(if(terminal&&!home)0f else 1f,tween(140),label="伙伴可见性")
    val base=with(LocalDensity.current){224.dp.toPx()}
    Box(Modifier.fillMaxSize().drawWithContent{
     val clipped=target.clip.height<target.rect.height-.5f||target.clip.width<target.rect.width-.5f
     if(settledRoute==route&&clipped)clipRect(target.clip.left-origin.x,target.clip.top-origin.y,target.clip.right-origin.x,target.clip.bottom-origin.y){this@drawWithContent.drawContent()}
     else drawContent()
    }){Box(Modifier.requiredSize(224.dp).graphicsLayer{
     translationX=bounds.left-origin.x;translationY=bounds.top-origin.y
     scaleX=bounds.width/base;scaleY=bounds.height/base
     transformOrigin=TransformOrigin(0f,0f);this.alpha=alpha
    }){
     if(alpha>.01f)CompanionCarousel(target.agent,target.state,interactive=home&&alpha>0f,compact=!home)
    }}
   }
  }
  AnimatedVisibility(vm.voiceDelivery.isNotBlank(),enter=fadeIn()+expandVertically(Motion.Resize),exit=fadeOut()+shrinkVertically(Motion.Resize)){
   Surface(Modifier.fillMaxWidth().padding(horizontal=18.dp,vertical=4.dp),color=CompanionGlow,shape=androidx.compose.foundation.shape.RoundedCornerShape(Radii.L),shadowElevation=Elev.Card){
    Row(Modifier.padding(Spacing.M),verticalAlignment=Alignment.CenterVertically){ThinkingDots();Text(vm.voiceDelivery,Modifier.weight(1f).padding(start=12.dp),fontSize=Type.Caption,color=Ink)}
   }
  }
  AnimatedVisibility((home||creating!=null||caps.optBoolean("input"))&&!terminal,enter=fadeIn(tween(180))+expandVertically(Motion.Resize),exit=fadeOut(tween(100))+shrinkVertically(Motion.Resize)){
   Column{
    vm.workReferences[route]?.let{MessageReferencePreview(it){vm.workReferences.remove(route)}}
    Composer(
     if(home)prompt else vm.draft(),
     {if(home){prompt=it;vm.store.savePrefSoon("new-draft",it)}else vm.setDraft(it)},
     if(home)"交给 ${agentDisplayName(agent)} 做点什么…" else if(creating!=null)"正在创建 ${vm.creatingAgent} 会话…" else if(status=="running")"写下补充内容…"else"继续和 ${session.optString("agent")} 聊聊…",
     vm.connected&&!vm.busy,!home&&status in listOf("running","waiting"),{modelPicker=true;vm.loadModels(pickerAgent)},
     {val text=if(home)prompt.trim() else vm.draft().trim();val rid=UUID.randomUUID().toString();motion.begin(rid,text)
      val sent=if(home)vm.create(agent,vm.store.prefs.getString("lastCwd","/Users/eddiegao/AI_Work_System")?:"",text,modelSelection.model,modelSelection.effort,"danger-full-access",rid)else vm.send(rid)
      if(sent==null)motion.cancel()else{motion.retarget(rid,sent);if(home)prompt=""}},
     {vm.stop()},voice,modelSelection.model.isNotBlank()||modelSelection.effort.isNotBlank(),motion,creating!=null,
    )
   }
  }
 }
 }
 LaunchedEffect(vm.busy,route){
  if(!vm.busy&&home&&prompt.isBlank())prompt=vm.store.prefs.getString("new-draft","").orEmpty()
  if(!vm.busy&&home&&motion.messageId!=null&&vm.outgoingMessages.none{it.id==motion.messageId})motion.cancel()
 }
 LaunchedEffect(route){if(!home&&vm.store.prefs.getString("new-draft",null)==null)prompt=""}
 if(modelPicker)ModelPickerSheet(
  pickerAgent,vm.catalogs[pickerAgent].orEmpty(),modelSelection.model,modelSelection.effort,
  vm.catalogLoading[pickerAgent]==true,vm.catalogErrors[pickerAgent],
  {modelPicker=false},
  {model,effort->vm.chooseModel(pickerAgent,pickerSid,model,effort);modelPicker=false},
  {vm.loadModels(pickerAgent,true)},
  existingSession=!home,
  allowDefaultModel=home||(session.optString("model").isBlank()&&session.optString("effort").isBlank()),
 )
}
