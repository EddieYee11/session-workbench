package work.eddie.sessions

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.*
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

// 灵动伙伴：暖白底、柔和卡片与克制的状态色，墨黑保留给文字和主操作。
val Ink=Color(0xFF292528);val Paper=Color(0xFFFAF6F4);val SidebarBg=Color(0xFFF5F0EE)
val Card=Color(0xFFFFFFFF);val Muted=Color(0xFF756B70);val Faint=Color(0xFF8D8187)
val Line=Color(0xFFECE2DE);val Track=Color(0xFFF0E8E5);val ChipBg=Color(0xFFF3ECE9)
val UserBubble=Color(0xFFF1E7E3);val ToolSurface=Color(0xFFF5F1EF)
val Accent=Ink;val AccentSoft=Color(0xFFF0E3DD);val AccentInk=Ink
val CompanionCoral=Color(0xFFC57665);val CompanionBlue=Color(0xFF5F8794)
val CompanionGlow=Color(0xFFE2EFF0);val CompanionBlush=Color(0xFFF8EAE3)
val PiGreen=Color(0xFF396C55);val PiSoft=Color(0xFFE7F2EC)
val AmberBg=Color(0xFFFFF7E8);val AmberLine=Color(0xFFF0E0B0);val AmberText=Color(0xFF8A6D1D)
val ApprovalBg=AmberBg

val Palette=lightColorScheme(
 primary=Ink,onPrimary=Color.White,primaryContainer=AccentSoft,onPrimaryContainer=Ink,
 secondary=CompanionCoral,secondaryContainer=CompanionBlush,onSecondaryContainer=Ink,
 background=Paper,onBackground=Ink,surface=Card,onSurface=Ink,
 surfaceVariant=ToolSurface,onSurfaceVariant=Muted,outline=Line)

// 动效规范：弹簧为主，全 App 节奏一致
object Motion{
 val TravelEasing=CubicBezierEasing(.22f,1f,.36f,1f)
 val Reveal=spring<Int>(dampingRatio=.95f,stiffness=Spring.StiffnessMedium)
 val Emphasized=spring<Float>(dampingRatio=.8f,stiffness=Spring.StiffnessMediumLow)
 val Gentle=spring<Float>(dampingRatio=.88f,stiffness=Spring.StiffnessMedium)
 val Settle=spring<Float>(dampingRatio=1f,stiffness=Spring.StiffnessMedium)
 val Bouncy=spring<Float>(dampingRatio=Spring.DampingRatioMediumBouncy,stiffness=Spring.StiffnessHigh)
 val Fade=tween<Float>(180,easing=FastOutSlowInEasing)
 val Slide=spring<IntOffset>(dampingRatio=.9f,stiffness=Spring.StiffnessMedium)
 val Tint=tween<Color>(200,easing=FastOutSlowInEasing)
 val Glide=spring<Dp>(dampingRatio=.88f,stiffness=Spring.StiffnessMedium)
 val Resize=spring<IntSize>(dampingRatio=.9f,stiffness=Spring.StiffnessMedium)
}

// 按压反馈：缩小回弹，搭配 interactionSource 挂到真实按钮上
@Composable fun rememberPress(scaleTo:Float=.92f):Pair<MutableInteractionSource,Modifier>{
 val src=remember{MutableInteractionSource()}
 val pressed by src.collectIsPressedAsState()
 val scale by animateFloatAsState(if(pressed)scaleTo else 1f,Motion.Bouncy,label="pressScale")
 return src to Modifier.scale(scale)
}

// 列表新条目进入：淡入 + 轻微上浮；active=false 时直通（避免历史消息滚动回屏时重复播放）
@Composable fun RowAppear(modifier:Modifier=Modifier,active:Boolean=true,content:@Composable ()->Unit){
 if(!active){Box(modifier){content()};return}
 var shown by remember{mutableStateOf(false)}
 LaunchedEffect(Unit){shown=true}
 AnimatedVisibility(visible=shown,modifier=modifier,enter=fadeIn(Motion.Fade)+slideInVertically(Motion.Slide){it/6}){content()}
}

// 页面入场：按 delay 分层淡入上浮，首页/页首使用
@Composable fun EnterAnim(delay:Int=0,content:@Composable ()->Unit){
 var shown by remember{mutableStateOf(false)}
 LaunchedEffect(Unit){shown=true}
 AnimatedVisibility(visible=shown,enter=fadeIn(tween(340,delay,FastOutSlowInEasing))+slideInVertically(spring(dampingRatio=.85f,stiffness=Spring.StiffnessMediumLow)){it/9}){content()}
}

// 呼吸状态点：运行中会话/连接状态
@Composable fun StatusDot(color:Color=Accent,size:Dp=6.dp){
 val t=rememberInfiniteTransition(label="dot")
 val a by t.animateFloat(1f,.2f,infiniteRepeatable(tween(900,easing=FastOutSlowInEasing),RepeatMode.Reverse),label="a")
 Box(Modifier.size(size).background(color.copy(alpha=a),CircleShape))
}

// 三点打字指示器：依次起伏
@Composable fun ThinkingDots(color:Color=Ink){
 val t=rememberInfiniteTransition(label="think")
 Row(horizontalArrangement=Arrangement.spacedBy(4.dp)){
  listOf(0,1,2).forEach{i->
   val y by t.animateFloat(0f,-4f,infiniteRepeatable(tween(520,delayMillis=i*130,easing=FastOutSlowInEasing),RepeatMode.Reverse),label="y$i")
   Box(Modifier.offset{IntOffset(0,y.roundToInt())}.size(6.dp).background(color,CircleShape))
  }
 }
}
