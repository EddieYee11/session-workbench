package work.eddie.sessions

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// 参考 Jakub Antalik 的 voice-glow：贴着容器底边的声波光晕，说话时升起、向两侧铺开、
// 颜色横向流动；静默时留一点呼吸感；转写中收成一道左右往返扫过的光束。
// 只借形态，配色沿用 Com! 自己的暖色（Hermes 珊瑚橙 + 点缀金）与冷色处理态。
private val VoiceWarm = Color(0xFFD2703F)
private val VoiceGold = Color(0xFFC99A3C)
private val VoiceCool = CompanionBlue

/**
 * 底边语音光晕。放在内容之上、并与容器同形裁剪的 Box 里。
 *
 * @param level 0~1 的实时音量；[active] 为 false 时收光。
 * @param processing 转写/思考态：改用冷色并叠一道左右往返的光束。
 */
@Composable
internal fun VoiceGlow(
 level: Float,
 processing: Boolean,
 active: Boolean,
 modifier: Modifier = Modifier,
 reach: Dp = 30.dp
){
 // 起音快、收音慢：50ms 采样下用不同时长的补间近似 attack/release。
 val energy = remember{Animatable(0f)}
 LaunchedEffect(level,active){
  val target=if(active)level.coerceIn(0f,1f) else 0f
  energy.animateTo(target,tween(if(target>energy.value)70 else 280,easing=LinearEasing))
 }
 val motion=rememberInfiniteTransition(label="voice-glow")
 val flow by motion.animateFloat(0f,1f,infiniteRepeatable(tween(3400,easing=LinearEasing),RepeatMode.Restart),label="flow")
 val sweep by motion.animateFloat(0f,1f,infiniteRepeatable(tween(1500,easing=FastOutSlowInEasing),RepeatMode.Reverse),label="sweep")
 val breathe by motion.animateFloat(0f,1f,infiniteRepeatable(tween(2600,easing=FastOutSlowInEasing),RepeatMode.Reverse),label="breathe")
 val fade by animateFloatAsState(if(active)1f else 0f,tween(240,easing=LinearEasing),label="fade")
 val reachPx=with(LocalDensity.current){reach.toPx()}
 val edgePx=with(LocalDensity.current){1.6.dp.toPx()}

 Canvas(modifier){
  val w=size.width;val h=size.height
  if(w<=0f||h<=0f||reachPx<=0f||fade<=0.001f)return@Canvas
  val e=energy.value.coerceIn(0f,1f)
  // 静默时也保留一点呼吸，避免录音中看起来像没在听。
  val band=(reachPx*(0.14f+0.05f*breathe+0.84f*e)).coerceIn(0f,reachPx)
  val tint=if(processing)VoiceCool else VoiceWarm
  val accent=if(processing)Color(0xFF9CBFCC) else VoiceGold

  // 1) 泛光：用低透明度的高梯度冒充模糊，零依赖。
  val bloom=band*2.2f
  drawRect(
   brush=Brush.verticalGradient(listOf(Color.Transparent,tint.copy(alpha=(0.10f+0.12f*e)*fade)),startY=h-bloom,endY=h),
   topLeft=Offset(0f,h-bloom),size=Size(w,bloom)
  )
  // 2) 内光：贴着底边的实心带。
  drawRect(
   brush=Brush.verticalGradient(listOf(Color.Transparent,tint.copy(alpha=(0.30f+0.34f*e)*fade)),startY=h-band,endY=h),
   topLeft=Offset(0f,h-band),size=Size(w,band)
  )
  // 3) 描边：横向流动的色带，是光晕的“芯”。
  val span=3f*w
  val startX=-span+flow*span
  val core=listOf(Color.Transparent,accent.copy(alpha=(0.55f+0.3f*e)*fade),tint.copy(alpha=0.85f*fade),accent.copy(alpha=(0.55f+0.3f*e)*fade),Color.Transparent)
  val edge=edgePx.coerceAtMost(h*0.5f)
  drawRect(
   brush=Brush.horizontalGradient(core,startX=startX,endX=startX+span),
   topLeft=Offset(0f,h-edge),size=Size(w,edge)
  )
  // 4) 处理态：一道左右往返的光束压在光带上。
  if(processing){
   val beamW=(w*0.30f).coerceAtLeast(1f)
   val cx=sweep*w
   drawRect(
    brush=Brush.horizontalGradient(
     listOf(Color.Transparent,Color.White.copy(alpha=0.45f*fade),Color.Transparent),
     startX=cx-beamW,endX=cx+beamW
    ),
    topLeft=Offset(0f,h-band),size=Size(w,band)
   )
  }
 }
}
