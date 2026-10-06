package work.eddie.sessions

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.Gravity
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
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * ASSIST 只启动底部快速语音小窗，转写后持久交办给原生 Hermes；从不打开主界面。
 * 记账使用独立 ExpenseVoiceActivity，继续复用原确认和投递流程。
 */
open class QuickVoiceActivity:ComponentActivity(){
 private val vm:QuickVoiceModel by viewModels()
 protected open val conversationMode:Boolean=true
 override fun onCreate(savedInstanceState:Bundle?){
  super.onCreate(savedInstanceState)
  if(conversationMode)vm.useConversationMode()
  if(savedInstanceState==null)vm.requestRecordingOnOpen()
  window.setBackgroundDrawableResource(android.R.color.transparent)
  window.setLayout(WindowManager.LayoutParams.WRAP_CONTENT,WindowManager.LayoutParams.WRAP_CONTENT)
  window.setGravity(Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL)
  window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL)
  window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
  val lp=window.attributes
  lp.y=(28*resources.displayMetrics.density).toInt()
  window.attributes=lp
  setContent{MaterialTheme(colorScheme=Palette,typography=ComTypography,shapes=ComShapes){
   if(conversationMode)AssistantVoiceCard(vm,::closeWindow)else ExpenseVoiceCard(vm,::closeWindow)
  }}
 }
 override fun onStart(){super.onStart();vm.onForeground()}
 override fun onStop(){
  if(!isChangingConfigurations)vm.onBackground()
  super.onStop()
 }
 override fun onNewIntent(intent:android.content.Intent){super.onNewIntent(intent);setIntent(intent);vm.requestRecordingOnOpen()}
 @Suppress("DEPRECATION") private fun closeWindow(){finish();overridePendingTransition(0,0)}
}

class ExpenseVoiceActivity:QuickVoiceActivity(){override val conversationMode=false}

@Composable private fun AssistantVoiceCard(vm:QuickVoiceModel,dismiss:()->Unit){
 val context=LocalContext.current
 val scope=rememberCoroutineScope()
 val haptics=rememberComHaptics()
 var visible by remember{mutableStateOf(false)}
 fun close(){vm.cancelConversationCapture();visible=false;scope.launch{delay(210);dismiss()}}
 val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){
  if(it)vm.requestRecordingOnOpen()else{vm.permissionDenied();haptics(HapticCue.Reject)}
 }
 fun record(){
  if(context.checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)vm.record()
  else permission.launch(Manifest.permission.RECORD_AUDIO)
 }
 LaunchedEffect(Unit){visible=true}
 LaunchedEffect(vm.restored,vm.isForeground,vm.openRecordingRequest){
  if(vm.restored&&vm.isForeground&&vm.consumeRecordingOnOpen())record()
 }
 var previous by remember{mutableStateOf(vm.phase)}
 LaunchedEffect(vm.phase){
  when{
   vm.phase=="recording"&&previous!="recording"->haptics(HapticCue.RecordingStart)
   previous=="recording"&&vm.phase!="recording"->haptics(HapticCue.RecordingStop)
   vm.phase=="sent"&&previous!="sent"->haptics(HapticCue.Commit)
  }
  previous=vm.phase
  if(vm.phase=="sent"){delay(500);close()}
 }
 BackHandler{close()}
 val recording=vm.phase=="recording"
 val busy=vm.phase in listOf("transcribing","sending")
 val sent=vm.phase=="sent"
 val canRetrySending=vm.phase=="confirm"&&vm.transcript.isNotBlank()
 val botState=when{recording->"listening";busy->"thinking";sent->"happy";vm.message.isNotBlank()->"error";else->"idle"}
 val avatarSize by animateDpAsState(if(busy||sent)100.dp else 174.dp,spring(dampingRatio=.88f,stiffness=360f),label="Hermes 小窗形象尺寸")
 val heroHeight by animateDpAsState(if(busy||sent)88.dp else 164.dp,spring(dampingRatio=.88f,stiffness=360f),label="小窗回复空间")
 val contentScroll=rememberScrollState()
 LaunchedEffect(recording){if(recording)contentScroll.animateScrollTo(0)}
 // Keep the original card bounded on short screens while its content can scroll.
 val maximumHeight=(context.resources.configuration.screenHeightDp*.62f).dp
 Box(Modifier.padding(horizontal=12.dp),contentAlignment=Alignment.BottomCenter){
  AnimatedVisibility(visible,enter=fadeIn(tween(180))+slideInVertically(spring(dampingRatio=.9f,stiffness=360f)){it/2},exit=fadeOut(tween(180))+slideOutVertically(tween(210,easing=Motion.TravelEasing)){it/3}){
   Surface(Modifier.widthIn(max=500.dp).fillMaxWidth().heightIn(max=maximumHeight),shape=RoundedCornerShape(28.dp),color=MaterialTheme.colorScheme.surface,shadowElevation=8.dp){
    Column(Modifier.padding(horizontal=22.dp).padding(top=8.dp,bottom=18.dp),horizontalAlignment=Alignment.CenterHorizontally){
     Box(Modifier.padding(top=5.dp,bottom=6.dp).width(36.dp).height(4.dp).background(Muted.copy(alpha=.35f),CircleShape))
     Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
      Surface(color=PiSoft,shape=CircleShape){
       Row(Modifier.padding(horizontal=11.dp,vertical=7.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(6.dp)){
        Box(Modifier.size(5.dp).background(PiGreen,CircleShape))
        Text("Hermes · 随时聊",fontWeight=FontWeight.SemiBold,color=PiGreen,fontSize=12.sp)
       }
      }
      Spacer(Modifier.weight(1f))
      Text("Com!",color=Ink,fontSize=19.sp,fontWeight=FontWeight.Bold,letterSpacing=(-.6).sp)
      IconButton(onClick={close()},modifier=Modifier.size(38.dp)){Icon(Icons.Outlined.Close,"收起小窗",Modifier.size(20.dp),tint=Muted)}
     }
     Column(Modifier.weight(1f,fill=false).verticalScroll(contentScroll),horizontalAlignment=Alignment.CenterHorizontally){
      Box(Modifier.fillMaxWidth().height(heroHeight),contentAlignment=Alignment.Center){
       CompanionAvatar("pi",botState,Modifier.size(avatarSize),interactive=false)
      }
      AnimatedContent(when{recording->"说吧，Hermes 在听。";sent->"已排队，交给 Hermes。";busy->"正在交给 Hermes。";canRetrySending->"这句话，还在这里。";else->"想到了，就告诉 Hermes。"},transitionSpec={fadeIn(tween(160)) togetherWith fadeOut(tween(100))},label="voiceTitle"){
       Text(it,color=Ink,fontSize=if(busy||sent)22.sp else 25.sp,fontWeight=FontWeight.SemiBold,textAlign=TextAlign.Center)
      }
      Text(when{recording->"停顿后自动发送";sent->"可在 Com! 工作页查看结果";vm.phase=="transcribing"->"识别后自动发送";busy->"受理后在后台继续处理";else->"记账、收藏等由 Hermes 直接处理"},Modifier.padding(top=8.dp,bottom=12.dp),fontSize=12.sp,color=Muted)
      if(recording){
       MicLevels(vm.levels,vm.seconds,tall=true)
       TextButton(onClick=vm::cancelRecording){Text("取消这次录音",color=Muted)}
      }else if(busy)LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical=18.dp).height(3.dp),color=PiGreen,trackColor=PiSoft)
      if(vm.transcript.isNotBlank()&&!recording)Text(vm.transcript,Modifier.fillMaxWidth().padding(top=5.dp,bottom=10.dp),fontSize=12.sp,lineHeight=18.sp,color=Muted,maxLines=3,overflow=TextOverflow.Ellipsis)
      if(vm.message.isNotBlank()&&!recording)Text(vm.message,Modifier.fillMaxWidth().padding(top=5.dp,bottom=10.dp),fontSize=12.sp,lineHeight=18.sp,color=Muted)
      if(canRetrySending)TextButton(onClick={vm.retry();record()}){Text("重新说一句",color=Muted)}
     }
     val (press,motion)=rememberPress(.96f)
     val buttonColor by animateColorAsState(if(recording)PiGreen else Ink,Motion.Tint,label="语音主按钮")
     Button(onClick={when{recording->vm.finishRecording();canRetrySending->vm.sendConversation();else->{vm.retry();record()}}},enabled=!busy&&!sent,modifier=Modifier.fillMaxWidth().height(54.dp).padding(top=2.dp).then(motion),shape=Radii.Pill,interactionSource=press,colors=ButtonDefaults.buttonColors(containerColor=buttonColor)){
      Icon(if(recording||canRetrySending)Icons.Outlined.ArrowUpward else Icons.Outlined.Mic,null,Modifier.size(21.dp))
      Spacer(Modifier.width(8.dp))
      Text(when{recording->"说完了，立即发送";sent->"已交办给 Hermes";busy->"正在发送";canRetrySending->"重试发送这句话";vm.message.isNotBlank()->"重新说一句";else->"开始说话"},fontWeight=FontWeight.SemiBold)
     }
    }
   }
  }
 }
}

@Composable private fun ExpenseVoiceCard(vm:QuickVoiceModel,dismiss:()->Unit){
 val context=LocalContext.current
 val scope=rememberCoroutineScope()
 val haptics=rememberComHaptics()
 var visible by remember{mutableStateOf(false)}
 fun close(){vm.cancelPending();visible=false;scope.launch{delay(150);dismiss()}}
 val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){if(it)vm.requestRecordingOnOpen()else{vm.permissionDenied();haptics(HapticCue.Reject)}}
 fun record(){if(context.checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)vm.record()else permission.launch(Manifest.permission.RECORD_AUDIO)}
 LaunchedEffect(Unit){visible=true}
 LaunchedEffect(vm.restored,vm.isForeground,vm.openRecordingRequest){if(vm.restored&&vm.isForeground&&vm.consumeRecordingOnOpen())record()}
 // 录音边：开始/结束/助理接收成功给震动
 var prevPhase by remember{mutableStateOf(vm.phase)}
 LaunchedEffect(vm.phase){
  val p=vm.phase
  when{
   p=="recording"&&prevPhase!="recording"->haptics(HapticCue.RecordingStart)
   prevPhase=="recording"&&p!="recording"->haptics(HapticCue.RecordingStop)
   p=="sent"&&prevPhase!="sent"->haptics(HapticCue.Commit)
  }
  prevPhase=p
 }
 // confirm 页 3 秒倒计时后自动记账（没听清金额时不自动）
 var countdown by remember{mutableIntStateOf(3)}
 LaunchedEffect(vm.phase){
  if(vm.phase=="confirm"&&vm.expense?.amount!=null){
   countdown=3
   while(countdown>0){delay(1000);if(vm.phase!="confirm")break;countdown--}
   if(vm.phase=="confirm"&&countdown==0)vm.confirmExpense()
  }
 }
 // 助理接收成功 1.4 秒后自动收起
 LaunchedEffect(vm.phase){if(vm.phase=="sent"){delay(1400);close()}}
 BackHandler{close()}
 Box(Modifier.padding(horizontal=16.dp),contentAlignment=Alignment.BottomCenter){
  AnimatedVisibility(visible,enter=fadeIn(tween(180))+slideInVertically(spring(dampingRatio=.9f,stiffness=380f)){it/3},exit=fadeOut(tween(150))+slideOutVertically(tween(180)){it/3}){
   Surface(Modifier.widthIn(max=360.dp),shape=RoundedCornerShape(24.dp),color=Card,border=BorderStroke(1.dp,Line),shadowElevation=12.dp){
    Column(Modifier.padding(horizontal=20.dp,vertical=16.dp),horizontalAlignment=Alignment.CenterHorizontally){
     Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
      Icon(Icons.Outlined.ReceiptLong,"语音记账",Modifier.size(18.dp),tint=Muted)
      Text("语音记账",Modifier.padding(start=8.dp),fontSize=14.sp,fontWeight=FontWeight.SemiBold,color=Ink)
      Spacer(Modifier.weight(1f))
      IconButton(onClick={close()},modifier=Modifier.size(32.dp)){Icon(Icons.Outlined.Close,"关闭",Modifier.size(18.dp),tint=Muted)}
     }
     when(vm.phase){
      "recording"->{
       Box(Modifier.padding(top=10.dp),contentAlignment=Alignment.Center){
        PulseRing(PiGreen,Modifier.size(76.dp))
        Icon(Icons.Outlined.Mic,null,Modifier.size(30.dp),tint=Ink)
       }
       Text("说出这笔支出",Modifier.padding(top=10.dp),fontSize=16.sp,fontWeight=FontWeight.SemiBold,color=Ink)
       Text("例如：午饭三十五",Modifier.padding(top=4.dp),fontSize=12.sp,color=Muted)
       MicLevels(vm.levels,vm.seconds,Modifier.padding(top=8.dp))
       TextButton(onClick={vm.finishRecording()},Modifier.padding(top=2.dp)){Text("说完了",fontSize=14.sp)}
      }
      "transcribing"->{
       CircularProgressIndicator(Modifier.padding(top=18.dp).size(30.dp),strokeWidth=3.dp,color=Muted)
       Text("正在识别…",Modifier.padding(top=12.dp,bottom=8.dp),fontSize=13.sp,color=Muted)
      }
      "confirm"->ExpenseConfirm(vm,countdown,{vm.retry();record()},{haptics(HapticCue.Commit);vm.confirmExpense()},{close()})
      "sending"->{
       CircularProgressIndicator(Modifier.padding(top=18.dp).size(30.dp),strokeWidth=3.dp,color=Muted)
       Text("正在交给 Hermes…",Modifier.padding(top=12.dp,bottom=8.dp),fontSize=13.sp,color=Muted)
      }
      "sent"->{
       Icon(Icons.Outlined.CheckCircle,"已交办给 Hermes",Modifier.padding(top=14.dp).size(40.dp),tint=PiGreen)
       Text("已交办给 Hermes",Modifier.padding(top=8.dp,bottom=6.dp),fontSize=16.sp,fontWeight=FontWeight.SemiBold,color=Ink)
       Text("Hermes 会回查账本，结果见工作会话",fontSize=11.sp,color=Muted)
      }
      else->{
       if(vm.message.isNotBlank())Text(vm.message,Modifier.padding(top=10.dp),fontSize=13.sp,lineHeight=19.sp,color=if(vm.paired)Muted else AmberText,textAlign=TextAlign.Center)
       else Text("点下方开始说出这笔支出",Modifier.padding(top=10.dp),fontSize=13.sp,color=Muted)
       Row(Modifier.padding(top=8.dp),verticalAlignment=Alignment.CenterVertically){
        TextButton(onClick={vm.retry();record()}){Text("重说",fontSize=14.sp)}
        TextButton(onClick={close()}){Text("关闭",fontSize=14.sp,color=Muted)}
       }
      }
     }
    }
   }
  }
 }
}

@Composable private fun ExpenseConfirm(vm:QuickVoiceModel,countdown:Int,onRetry:()->Unit,onConfirm:()->Unit,onDismiss:()->Unit){
 val e=vm.expense
 if(e?.amount!=null){
  Text("¥${fmtAmount(e.amount!!)}",Modifier.padding(top=8.dp),fontSize=36.sp,fontWeight=FontWeight.Bold,color=Ink)
  Row(Modifier.padding(top=6.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)){
   Surface(color=ChipBg,shape=RoundedCornerShape(50)){Text(e.category,Modifier.padding(horizontal=10.dp,vertical=4.dp),fontSize=12.sp,color=Ink)}
   Text(e.note,fontSize=14.sp,color=Ink)
  }
  Text("“${vm.transcript.take(40)}”",Modifier.padding(top=8.dp),fontSize=11.sp,color=Faint,textAlign=TextAlign.Center)
  if(vm.message.isNotBlank())Text(vm.message,Modifier.padding(top=4.dp),fontSize=11.sp,color=AmberText)
  Text("$countdown 秒后交给 Hermes",Modifier.padding(top=6.dp),fontSize=11.sp,color=Muted)
  Row(Modifier.padding(top=10.dp),verticalAlignment=Alignment.CenterVertically){
   OutlinedButton(onClick=onRetry,shape=RoundedCornerShape(50)){Text("重说")}
   Spacer(Modifier.width(10.dp))
   Button(onClick=onConfirm,shape=RoundedCornerShape(50)){Text("交给 Hermes")}
  }
 }else{
  Text("没听清金额",Modifier.padding(top=8.dp),fontSize=16.sp,fontWeight=FontWeight.SemiBold,color=Ink)
  if(vm.transcript.isNotBlank())Text("“${vm.transcript.take(60)}”",Modifier.padding(top=6.dp),fontSize=12.sp,color=Muted,textAlign=TextAlign.Center)
  Text("再说一次，比如：午饭三十五",Modifier.padding(top=4.dp),fontSize=11.sp,color=Faint)
  Row(Modifier.padding(top=10.dp),verticalAlignment=Alignment.CenterVertically){
   OutlinedButton(onClick=onRetry,shape=RoundedCornerShape(50)){Text("重说")}
   Spacer(Modifier.width(10.dp))
   TextButton(onClick=onDismiss){Text("算了",color=Muted)}
  }
 }
}

@Composable private fun MicLevels(levels:List<Float>,seconds:Int,modifier:Modifier=Modifier,tall:Boolean=false){
 Row(modifier.fillMaxWidth().height(if(tall)60.dp else 44.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(15.dp)){
  androidx.compose.foundation.Canvas(Modifier.weight(1f).height(if(tall)38.dp else 34.dp).semantics{contentDescription="实时麦克风音量"}){
   val step=size.width/levels.size
   levels.forEachIndexed{i,level->val h=3.dp.toPx()+level*(size.height-3.dp.toPx());val x=step*(i+.5f);drawLine(CompanionBlue.copy(alpha=.35f+.65f*(i+1f)/levels.size),Offset(x,(size.height-h)/2),Offset(x,(size.height+h)/2),strokeWidth=3.dp.toPx(),cap=StrokeCap.Round)}
  }
  Text("0:${seconds.toString().padStart(2,'0')}",color=Muted,fontSize=13.sp,fontFamily=FontFamily.Monospace)
 }
}
