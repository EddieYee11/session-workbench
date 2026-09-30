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

// 质感浅色主题：暖纸面 + 靛蓝强调色 + 细腻分隔，对齐 Kimi 式精致感
val Ink=Color(0xFF16161A);val Paper=Color(0xFFF7F7F5);val Card=Color(0xFFFFFFFF)
val Muted=Color(0xFF6E6E76);val Faint=Color(0xFF9C9CA4);val Line=Color(0xFFE9E9E6)
val Accent=Color(0xFF3D5BF0);val AccentSoft=Color(0xFFEBEFFF);val AccentInk=Color(0xFF2C44C4)
val Glow=Accent.copy(alpha=.18f);val UserBubble=Color(0xFFEDEFF6);val ToolSurface=Color(0xFFF3F3F1)
val Track=Color(0xFFEBEBE9);val ApprovalBg=Color(0xFFFFF4DC)
val PiGreen=Color(0xFF396C55);val PiSoft=Color(0xFFE7F2EC)

val Palette=lightColorScheme(
 primary=Accent,onPrimary=Color.White,primaryContainer=AccentSoft,onPrimaryContainer=AccentInk,
 secondary=Ink,secondaryContainer=Color(0xFFEFEFED),onSecondaryContainer=Ink,
 background=Paper,onBackground=Ink,surface=Card,onSurface=Ink,
 surfaceVariant=Color(0xFFF1F1EE),onSurfaceVariant=Muted,outline=Line)

// 动效规范：全面丝滑化
object Motion{
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

// 呼吸状态点：运行中会话/连接状态
@Composable fun StatusDot(color:Color=Accent,size:Dp=6.dp){
 val t=rememberInfiniteTransition(label="dot")
 val a by t.animateFloat(1f,.2f,infiniteRepeatable(tween(900,easing=FastOutSlowInEasing),RepeatMode.Reverse),label="a")
 Box(Modifier.size(size).background(color.copy(alpha=a),CircleShape))
}

// 三点打字指示器：依次起伏
@Composable fun ThinkingDots(color:Color=Accent){
 val t=rememberInfiniteTransition(label="think")
 Row(horizontalArrangement=Arrangement.spacedBy(4.dp)){
  listOf(0,1,2).forEach{i->
   val y by t.animateFloat(0f,-4f,infiniteRepeatable(tween(520,delayMillis=i*130,easing=FastOutSlowInEasing),RepeatMode.Reverse),label="y$i")
   Box(Modifier.offset{IntOffset(0,y.roundToInt())}.size(6.dp).background(color,CircleShape))
  }
 }
}
