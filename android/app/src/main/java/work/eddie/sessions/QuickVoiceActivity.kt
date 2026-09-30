package work.eddie.sessions

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import io.noties.markwon.Markwon
import io.noties.markwon.ext.tables.TablePlugin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class QuickVoiceActivity:ComponentActivity(){
 private val vm:QuickVoiceModel by viewModels()
 companion object{fun launch(context:Context){context.startActivity(Intent(context,QuickVoiceActivity::class.java).setAction(Intent.ACTION_ASSIST).apply{if(context !is android.app.Activity)addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)})}}
 override fun onCreate(savedInstanceState:Bundle?){
  super.onCreate(savedInstanceState)
  if(savedInstanceState==null)vm.requestRecordingOnOpen()
  window.setBackgroundDrawableResource(android.R.color.transparent)
  window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
  setContent{MaterialTheme(colorScheme=Palette){QuickVoiceSheet(vm,this::closeWindow){
   if(vm.phase=="recording")vm.finishRecording()
   else if(vm.hasRecording&&vm.phase=="ready")vm.transcribe()
   startActivity(Intent(this,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP).apply{
    if(vm.sessionId.isNotBlank())putExtra("sid",vm.sessionId)
    else{putExtra("agent","pi");if(vm.deliveryId.isNotBlank())putExtra("voice_work",vm.deliveryId)}
   })
   closeWindow()
  }}}
 }
 override fun onStart(){super.onStart();vm.onForeground()}
 override fun onStop(){vm.onBackground();super.onStop()}
 override fun onNewIntent(intent:Intent){super.onNewIntent(intent);setIntent(intent);vm.requestRecordingOnOpen()}
 @Suppress("DEPRECATION") private fun closeWindow(){finish();overridePendingTransition(0,0)}
}

@Composable private fun QuickVoiceSheet(vm:QuickVoiceModel,dismiss:()->Unit,expand:()->Unit){
 val context=androidx.compose.ui.platform.LocalContext.current
 val scope=rememberCoroutineScope()
 var visible by remember{mutableStateOf(false)}
 var expanding by remember{mutableStateOf(false)}
 val expandLatest by rememberUpdatedState(expand)
 val expansion by animateFloatAsState(if(expanding)1f else 0f,tween(340,easing=Motion.TravelEasing),label="小窗拉成会话",finishedListener={if(it==1f)expandLatest()})
 fun beginExpansion(){if(expanding)return;if(vm.phase=="recording")vm.finishRecording();expanding=true}
 val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){if(it)vm.requestRecordingOnOpen()else vm.permissionDenied()}
 fun record(){if(context.checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)vm.record()else permission.launch(Manifest.permission.RECORD_AUDIO)}
 fun close(){vm.onBackground();visible=false;scope.launch{delay(210);dismiss()}}
 LaunchedEffect(Unit){visible=true}
 LaunchedEffect(vm.restored,vm.isForeground,vm.openRecordingRequest){if(vm.restored&&vm.isForeground&&vm.consumeRecordingOnOpen())record()}
 BackHandler{close()}
 val recording=vm.phase=="recording"
 val waiting=vm.phase in listOf("waiting","sent")
 val busy=waiting||vm.phase in listOf("queued","transcribing","sending")
 val replied=vm.phase=="reply"
 val hasReply=vm.replyText.isNotBlank()
 val conversational=waiting||replied||hasReply
 val botState=when{recording->"listening";waiting&&hasReply->"speaking";busy->"thinking";replied->"happy";vm.hasRecording&&vm.message.isNotBlank()->"curious";else->"idle"}
 val avatarSize by animateDpAsState(if(conversational&&!recording)100.dp else 174.dp,spring(dampingRatio=.88f,stiffness=360f),label="Pi 小窗形象尺寸")
 val heroHeight by animateDpAsState(if(conversational&&!recording)88.dp else 164.dp,spring(dampingRatio=.88f,stiffness=360f),label="小窗回复空间")
 val contentScroll=rememberScrollState()
 LaunchedEffect(recording){if(recording)contentScroll.animateScrollTo(0)}
 val scrim by animateFloatAsState(if(visible)1f else 0f,tween(210),label="voiceScrim")
 val dragThreshold=with(LocalDensity.current){54.dp.toPx()}
 val expandCurrent by rememberUpdatedState(::beginExpansion)
 Box(Modifier.fillMaxSize()){
  Box(Modifier.fillMaxSize().background(Color(0xFF152A2B).copy(alpha=.22f*scrim)).clickable(remember{MutableInteractionSource()},indication=null){close()})
  BoxWithConstraints(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(horizontal=12.dp,vertical=8.dp),contentAlignment=Alignment.BottomCenter){
   val available=maxHeight
   val density=LocalDensity.current
   var measuredHeight by remember{mutableStateOf(0.dp)}
   val panelWidth=500.dp+(maxWidth-500.dp).coerceAtLeast(0.dp)*expansion
   val panelHeight=measuredHeight+(available-measuredHeight)*expansion
   AnimatedVisibility(visible,enter=fadeIn(tween(180))+slideInVertically(spring(dampingRatio=.9f,stiffness=360f)){it/2},exit=fadeOut(tween(180))+slideOutVertically(tween(210,easing=Motion.TravelEasing)){it/3}){
    Surface(Modifier.widthIn(max=panelWidth).fillMaxWidth().then(if(expanding&&measuredHeight>0.dp)Modifier.height(panelHeight)else Modifier.heightIn(max=available)).onSizeChanged{if(!expanding)measuredHeight=with(density){it.height.toDp()}}.clickable(remember{MutableInteractionSource()},indication=null){},shape=RoundedCornerShape(Radii.Xxxl*(1f-expansion)),color=Paper,shadowElevation=Elev.Sheet*(1f-expansion),border=BorderStroke(1.dp,Color.White.copy(alpha=.9f))){
     Column(Modifier.padding(horizontal=22.dp).padding(top=8.dp,bottom=18.dp),horizontalAlignment=Alignment.CenterHorizontally){
      Column(Modifier.fillMaxWidth().pointerInput(dragThreshold){var pull=0f;detectVerticalDragGestures(onDragStart={pull=0f},onDragEnd={if(pull < -dragThreshold)expandCurrent()},onVerticalDrag={change,amount->change.consume();pull+=amount})},horizontalAlignment=Alignment.CenterHorizontally){
       Box(Modifier.padding(top=5.dp,bottom=6.dp).width(32.dp).height(4.dp).background(Line,CircleShape))
       Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
        Surface(color=PiSoft,shape=CircleShape){Row(Modifier.padding(horizontal=11.dp,vertical=7.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(6.dp)){Box(Modifier.size(5.dp).background(PiGreen,CircleShape));Text(if(vm.sessionId.isBlank())"Pi · 随时聊" else "Pi · 对话中",fontWeight=FontWeight.SemiBold,color=PiGreen,fontSize=12.sp)}}
        Spacer(Modifier.weight(1f));Text("Com!",color=Ink,fontSize=19.sp,fontWeight=FontWeight.Bold,letterSpacing=(-.6).sp)
        IconButton(onClick=::beginExpansion,modifier=Modifier.size(42.dp)){Icon(Icons.Outlined.OpenInFull,"展开到会话",Modifier.size(19.dp),tint=Ink)}
        IconButton(onClick={close()},modifier=Modifier.size(38.dp)){Icon(Icons.Outlined.Close,"收起小窗",Modifier.size(20.dp),tint=Muted)}
       }
      }
      Column(Modifier.weight(1f,fill=false).verticalScroll(contentScroll),horizontalAlignment=Alignment.CenterHorizontally){
       Box(Modifier.fillMaxWidth().height(heroHeight),contentAlignment=Alignment.Center){
        Box(Modifier.size(avatarSize*.92f).background(Brush.radialGradient(listOf(CompanionGlow.copy(alpha=.85f),Color.Transparent)),CircleShape))
        CompanionAvatar("pi",botState,Modifier.size(avatarSize),interactive=false)
       }
       AnimatedContent(when{recording->"说吧，Pi 在听。";waiting&&hasReply->"Pi 正在回复。";waiting->"Pi 正在想…";replied->"我在，接着聊。";vm.phase=="queued"->"这句话，已经收好。";busy->"正在交给 Pi。";vm.hasRecording->"这句话，还在这里。";else->"想到了，就告诉 Pi。"},transitionSpec={fadeIn(tween(180)) togetherWith fadeOut(tween(120))},label="voiceTitle"){Text(it,color=Ink,fontSize=if(conversational&&!recording)23.sp else 26.sp,fontFamily=FontFamily.Serif,fontWeight=FontWeight.Medium,letterSpacing=(-.5).sp)}
       Text(when{recording->"停顿 0.5 秒自动发送 · 也可手动发送";waiting->"回复会直接出现在这里";replied->"继续说一句，或上滑展开详细对话";busy->"收起小窗后也会继续发送";else->"直接交给 Pi，无需文字确认"},Modifier.padding(top=8.dp,bottom=12.dp),fontSize=12.sp,color=Muted)
       if(recording){MicLevels(vm.levels,vm.seconds);TextButton(onClick=vm::cancelRecording){Text("取消这次录音",color=Muted)}}
       else if(busy&&!hasReply)LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical=18.dp).height(3.dp),color=PiGreen,trackColor=PiSoft)
       AnimatedVisibility(hasReply&&!recording,enter=fadeIn(tween(220))+expandVertically(tween(260,easing=Motion.TravelEasing)),exit=fadeOut(tween(100))){
        Surface(Modifier.fillMaxWidth().padding(top=2.dp,bottom=18.dp),shape=RoundedCornerShape(Radii.Xxl),color=PiSoft,shadowElevation=Elev.Card){
         Column(Modifier.padding(horizontal=18.dp,vertical=17.dp)){
          Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(7.dp)){
           Box(Modifier.size(5.dp).background(PiGreen,CircleShape))
           Text(if(waiting)"Pi 正在回复" else "Pi",fontSize=11.sp,color=PiGreen,fontWeight=FontWeight.SemiBold)
          }
          AndroidView(modifier=Modifier.fillMaxWidth().padding(top=10.dp),factory={c->
           MarkdownTextView(c).apply{setTextColor(android.graphics.Color.rgb(41,37,40));textSize=16f;setTextIsSelectable(true);setLineSpacing(7*resources.displayMetrics.density,1f);tag=Markwon.builder(c).usePlugin(TablePlugin.create(c)).build()}
          },update={v->(v.tag as Markwon).setMarkdown(v,vm.replyText)})
          if(waiting)LinearProgressIndicator(Modifier.fillMaxWidth().padding(top=14.dp).height(2.dp),color=PiGreen.copy(alpha=.6f),trackColor=Color.White.copy(alpha=.6f))
         }
        }
       }
       if(vm.message.isNotBlank()&&!recording)Text(vm.message,Modifier.fillMaxWidth().padding(top=5.dp,bottom=10.dp),fontSize=12.sp,lineHeight=18.sp,color=Muted)
       if(vm.hasRecording&&!busy&&!recording)TextButton(onClick={record()}){Text("重新说一句",color=Muted)}
      }
      val (press,motion)=rememberPress(.96f)
      Button(onClick={when{recording->vm.finishRecording();vm.hasRecording->vm.transcribe();else->record()}},enabled=!busy&&!expanding,modifier=Modifier.fillMaxWidth().height(54.dp).padding(top=2.dp).then(motion),shape=Radii.Pill,interactionSource=press,colors=ButtonDefaults.buttonColors(containerColor=Ink)){
       Icon(if(recording||vm.hasRecording)Icons.Outlined.ArrowUpward else Icons.Outlined.Mic,null,Modifier.size(21.dp));Spacer(Modifier.width(8.dp));Text(when{recording->"说完了，立即发送";waiting->"正在等 Pi 回复";busy->"正在发送";vm.hasRecording->"重试发送这段录音";replied||vm.sessionId.isNotBlank()->"再说一句";else->"开始说话"},fontWeight=FontWeight.SemiBold)
      }
      Text("上滑展开 · ${vm.cwd.shortPath()}",Modifier.padding(top=12.dp),color=Faint,fontSize=11.sp)
     }
    }
   }
  }
 }
}

@Composable private fun MicLevels(levels:List<Float>,seconds:Int){
 Row(Modifier.fillMaxWidth().height(60.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(15.dp)){
  Canvas(Modifier.weight(1f).height(38.dp).semantics{contentDescription="实时麦克风音量"}){
   val step=size.width/levels.size
   levels.forEachIndexed{i,level->val h=3.dp.toPx()+level*(size.height-3.dp.toPx());val x=step*(i+.5f);drawLine(CompanionBlue.copy(alpha=.35f+.65f*(i+1f)/levels.size),androidx.compose.ui.geometry.Offset(x,(size.height-h)/2),androidx.compose.ui.geometry.Offset(x,(size.height+h)/2),strokeWidth=3.dp.toPx(),cap=StrokeCap.Round)}
  }
  Text("0:${seconds.toString().padStart(2,'0')}",color=Muted,fontSize=13.sp,fontFamily=FontFamily.Monospace)
 }
}
