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
 val route=vm.selected.ifBlank{"home"}
 val home=route=="home"
 var prompt by rememberSaveable{mutableStateOf(vm.store.prefs.getString("new-draft","")?:"")}
 var options by remember{mutableStateOf(false)}
 var terminal by rememberSaveable(vm.selected){mutableStateOf(false)}
 val session=vm.detail.optJSONObject("session")?:JSONObject()
 val caps=session.optJSONObject("capabilities")?:JSONObject()
 val status=vm.live.optString("status",session.optString("status"))
 var origin by remember{mutableStateOf(Offset.Zero)}
 var lastAnchor by remember{mutableStateOf<CompanionAnchor?>(null)}
 val anchor=stage.anchors[route]?:lastAnchor
 SideEffect{stage.anchors[route]?.let{lastAnchor=it}}
 val voice:()->Unit={context.startActivity(Intent(context,QuickVoiceActivity::class.java))}
 Column(Modifier.fillMaxSize()){
  Box(Modifier.weight(1f).fillMaxWidth().clipToBounds().onGloballyPositioned{origin=it.positionInRoot()}){
   CompositionLocalProvider(LocalCompanionStage provides stage){
    AnimatedContent(route,modifier=Modifier.fillMaxSize(),transitionSpec={
     (fadeIn(tween(240,90))+slideInVertically(tween(380,easing=Motion.TravelEasing)){if(targetState=="home")-it/35 else it/35}) togetherWith
      fadeOut(tween(150)) using SizeTransform(clip=false)
    },label="连续会话场景"){scene->
     CompositionLocalProvider(LocalSceneKey provides scene){
      Box(Modifier.fillMaxSize().then(if(scene!=route)Modifier.clearAndSetSemantics{} else Modifier)){
      if(scene=="home")NewChatHome(vm,agent,select,menu,advanced,pick)
      else{
       var snapshot by remember(scene){mutableStateOf(ConversationSnapshot(scene,vm.detail,vm.live,vm.liveFresh&&vm.liveSessionId==scene))}
       val current=if(vm.selected==scene)ConversationSnapshot(scene,vm.detail,vm.live,vm.liveFresh&&vm.liveSessionId==scene) else snapshot
       SideEffect{if(vm.selected==scene)snapshot=current}
       ChatPage(vm,menu,new,current,terminal,{terminal=it},scene==route)
      }
      if(scene!=route)Box(Modifier.matchParentSize().pointerInput(Unit){awaitPointerEventScope{while(true){awaitPointerEvent().changes.forEach{it.consume()}}}})
      }
     }
    }
   }
   anchor?.let{target->
    val travel=remember{Animatable(target.rect,Rect.VectorConverter)}
    var settledRoute by remember{mutableStateOf(route)}
    LaunchedEffect(route,target.rect){
     if(settledRoute!=route){travel.animateTo(target.rect,tween(460,easing=Motion.TravelEasing));settledRoute=route}
     else travel.snapTo(target.rect)
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
  AnimatedVisibility((home||caps.optBoolean("input"))&&!terminal,enter=fadeIn(tween(180))+expandVertically(Motion.Resize),exit=fadeOut(tween(100))+shrinkVertically(Motion.Resize)){
   Column{
    Composer(
     if(home)prompt else vm.draft(),
     {if(home){prompt=it;vm.store.prefs.edit().putString("new-draft",it).apply()}else vm.setDraft(it)},
     if(home)"交给 ${if(agent=="pi")"Pi"else"Codex"} 做点什么…" else if(status=="running")"写下补充内容…"else"继续和 ${session.optString("agent")} 聊聊…",
     vm.connected&&!vm.busy,!home&&status in listOf("running","waiting"),{options=true},
     {if(home)vm.create(agent,vm.store.prefs.getString("lastCwd","/Users/eddiegao/AI_Work_System")?:"",prompt,"","","danger-full-access")else vm.send()},
     {vm.stop()},voice,
    )
    AnimatedContent(home,transitionSpec={fadeIn(tween(120)) togetherWith fadeOut(tween(90))},label="输入状态说明") {isHome->
     Text(if(isHome)"Com! · 想到，就一起做到" else "Com! · ${if(session.optString("agent")=="pi")"Pi"else"Codex"} 与你同在",Modifier.fillMaxWidth().padding(bottom=8.dp),fontSize=Type.Tiny,color=Faint,textAlign=androidx.compose.ui.text.style.TextAlign.Center)
    }
   }
  }
 }
 LaunchedEffect(route){if(!home&&vm.store.prefs.getString("new-draft",null)==null)prompt=""}
 LaunchedEffect(options,home){if(options&&home){options=false;advanced()}}
 if(options&&!home)SessionMenu(vm,session){options=false}
}
