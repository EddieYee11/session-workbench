package work.eddie.sessions

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.*
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt

// 灵动伙伴：暖白底、柔和卡片与克制的状态色，墨黑保留给文字和主操作。
val Ink=Color(0xFF292528);val Paper=Color(0xFFFAF6F4);val SidebarBg=Color(0xFFF5F0EE)
val Card=Color(0xFFFFFFFF);val Muted=Color(0xFF756B70);val Faint=Color(0xFF7D7177)
val Line=Color(0xFFECE2DE);val Track=Color(0xFFF0E8E5);val ChipBg=Color(0xFFF3ECE9)
val UserBubble=Color(0xFFF1E7E3);val ToolSurface=Color(0xFFF5F1EF)
val Accent=Ink;val AccentSoft=Color(0xFFF0E3DD);val AccentInk=Ink
val CompanionCoral=Color(0xFFC57665);val CompanionBlue=Color(0xFF5F8794)
val CompanionGlow=Color(0xFFE2EFF0);val CompanionBlush=Color(0xFFF8EAE3)
val PiGreen=Color(0xFF396C55);val PiSoft=Color(0xFFE7F2EC)
val AmberBg=Color(0xFFFFF7E8);val AmberLine=Color(0xFFF0E0B0);val AmberText=Color(0xFF8A6D1D)
val ApprovalBg=AmberBg
val Danger=Color(0xFFB24A3D);val Success=PiGreen

// ===== Com! 2.0 · 大改视觉语言 =====
// 暖雾纵深：顶部微光 → 纸面 → 底部暖调，页面有了呼吸感
val WashTop=Color(0xFFFFFCF9);val WashMid=Color(0xFFFAF6F3);val WashBottom=Color(0xFFF2EAE3)
// 主操作暖赭：关键 CTA 的温度色，墨黑留给文字
val Ember=Color(0xFFB4552D);val EmberDeep=Color(0xFF8F3E1E);val EmberSoft=Color(0xFFF8E9DC)
// 点缀金：状态徽标与高光
val Gold=Color(0xFFC99A3C);val GoldSoft=Color(0xFFFAF0DA)

val Palette=lightColorScheme(
 primary=Ink,onPrimary=Color.White,primaryContainer=AccentSoft,onPrimaryContainer=Ink,
 secondary=CompanionCoral,secondaryContainer=CompanionBlush,onSecondaryContainer=Ink,
 tertiary=Ember,onTertiary=Color.White,tertiaryContainer=EmberSoft,onTertiaryContainer=EmberDeep,
 background=Paper,onBackground=Ink,surface=Card,onSurface=Ink,
 surfaceVariant=ToolSurface,onSurfaceVariant=Muted,outline=Line)

// 设计刻度：间距 / 圆角 / 阴影 / 字阶全 App 统一，不再随手写数字
object Spacing{
 val Xs=4.dp;val S=8.dp;val M=12.dp;val L=16.dp;val Xl=20.dp;val Xxl=24.dp;val Xxxl=32.dp
}
object Radii{
 val S=8.dp;val M=12.dp;val L=16.dp;val Xl=20.dp;val Xxl=24.dp;val Sheet=28.dp;val Xxxl=32.dp
 val Pill=RoundedCornerShape(50)
}
object Elev{
 val Card=2.dp;val Raised=4.dp;val Sheet=12.dp
}
// 字阶：标题 / 正文 / 辅助 / 微型
object Type{
 val SheetTitle=24.sp;val AppTitle=22.sp;val Section=17.sp
 val Body=15.sp;val BodySm=13.sp;val Caption=12.sp;val Micro=11.sp;val Tiny=10.sp
}
// 行高搭配：与字阶成对使用
object Leading{
 val Hero=46.sp;val Title=30.sp;val Body=24.sp;val Caption=18.sp
}

// 暖色柔光阴影：比纯黑投影更有温度
fun Modifier.softShadow(elevation:Dp,shape:Shape=RoundedCornerShape(Radii.Xl),spot:Color=Color(0x2E8A5A33),ambient:Color=Color(0x14000000))=this.shadow(elevation,shape,clip=false,spotColor=spot,ambientColor=ambient)

// 暖雾背景：页面纵深的底
@Composable fun WashBackground(modifier:Modifier=Modifier,content:@Composable ()->Unit){
 Box(modifier.background(Brush.verticalGradient(listOf(WashTop,WashMid,WashBottom)))){
  Box(Modifier.fillMaxWidth().height(300.dp).background(Brush.verticalGradient(listOf(Color.White.copy(alpha=.85f),Color.Transparent))))
  content()
 }
}

// 统一卡片：白底 + 1dp 暖灰描边 + 柔和投影，各处卡片不再各写一套
@Composable fun PolishCard(modifier:Modifier=Modifier,radius:Dp=Radii.Xl,onClick:(()->Unit)?=null,content:@Composable ()->Unit){
 if(onClick!=null)Surface(onClick=onClick,modifier=modifier,shape=RoundedCornerShape(radius),color=Card,border=BorderStroke(1.dp,Line),shadowElevation=Elev.Card){content()}
 else Surface(modifier=modifier,shape=RoundedCornerShape(radius),color=Card,border=BorderStroke(1.dp,Line),shadowElevation=Elev.Card){content()}
}

// 主角卡片：渐变描边 + 暖光投影，用于首页焦点会话等最重要的入口
@Composable fun HeroCard(modifier:Modifier=Modifier,onClick:(()->Unit)?=null,content:@Composable ()->Unit){
 val (press,pressMod)=rememberPress(.97f)
 val edge=Brush.linearGradient(listOf(Ember.copy(alpha=.55f),Gold.copy(alpha=.45f),CompanionCoral.copy(alpha=.35f)))
 Box(modifier.then(pressMod).softShadow(10.dp,RoundedCornerShape(Radii.Xxl)).background(edge,RoundedCornerShape(Radii.Xxl)).padding(1.5.dp).clip(RoundedCornerShape(Radii.Xxl)).background(Card).then(if(onClick!=null)Modifier.clickable(interactionSource=press,indication=null){onClick()}else Modifier)){content()}
}

// 空状态：图标 + 标题 + 提示，居中；用于列表无内容与无搜索结果
@Composable fun EmptyState(icon:ImageVector,title:String,hint:String){
 var shown by remember{mutableStateOf(false)}
 LaunchedEffect(Unit){shown=true}
 AnimatedVisibility(visible=shown,enter=fadeIn(tween(420,120))+slideInVertically(spring(dampingRatio=.9f,stiffness=Spring.StiffnessMediumLow)){it/8}){
  Column(Modifier.fillMaxWidth().padding(Spacing.Xxl),horizontalAlignment=Alignment.CenterHorizontally){
   Box(Modifier.size(56.dp).background(ChipBg,CircleShape),contentAlignment=Alignment.Center){Icon(icon,null,Modifier.size(26.dp),tint=Faint)}
   Text(title,Modifier.padding(top=Spacing.M),fontSize=Type.Body,fontWeight=FontWeight.Medium,color=Muted)
   Text(hint,Modifier.padding(top=Spacing.Xs),fontSize=Type.Caption,color=Faint,textAlign=TextAlign.Center,lineHeight=18.sp)
  }
 }
}

// 分组小标题：字母间距拉开的微型标题
@Composable fun SectionHeader(text:String,modifier:Modifier=Modifier){
 Text(text,modifier,fontSize=11.sp,fontWeight=FontWeight.Bold,color=Faint,letterSpacing=1.4.sp)
}

// 动效规范：弹簧为主，全 App 节奏一致
object Motion{
 val TravelEasing=CubicBezierEasing(.22f,1f,.36f,1f)
 val Reveal=spring<Int>(dampingRatio=.95f,stiffness=Spring.StiffnessMedium)
 val Emphasized=spring<Float>(dampingRatio=.8f,stiffness=Spring.StiffnessMediumLow)
 val Gentle=spring<Float>(dampingRatio=.88f,stiffness=Spring.StiffnessMedium)
 val Settle=spring<Float>(dampingRatio=1f,stiffness=Spring.StiffnessMedium)
 val Bouncy=spring<Float>(dampingRatio=Spring.DampingRatioMediumBouncy,stiffness=Spring.StiffnessHigh)
 val Pop=spring<Float>(dampingRatio=.72f,stiffness=Spring.StiffnessMediumLow)
 val Fade=tween<Float>(180,easing=FastOutSlowInEasing)
 val Slide=spring<IntOffset>(dampingRatio=.9f,stiffness=Spring.StiffnessMedium)
 val Tint=tween<Color>(200,easing=FastOutSlowInEasing)
 val Glide=spring<Dp>(dampingRatio=.88f,stiffness=Spring.StiffnessMedium)
 val Resize=spring<IntSize>(dampingRatio=.9f,stiffness=Spring.StiffnessMedium)
 // 列表 stagger 延迟：按序号递增，上限 8 项
 fun staggerDelay(index:Int)=(index.coerceAtMost(8)*55)
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

// 列表 stagger 入场：按序号延迟，首屏列表依次浮现
@Composable fun StaggerIn(index:Int,modifier:Modifier=Modifier,content:@Composable ()->Unit){
 var shown by remember{mutableStateOf(false)}
 LaunchedEffect(Unit){shown=true}
 AnimatedVisibility(visible=shown,modifier=modifier,
  enter=fadeIn(tween(320,Motion.staggerDelay(index),FastOutSlowInEasing))+slideInVertically(spring(dampingRatio=.9f,stiffness=Spring.StiffnessMediumLow)){it/7},
  exit=fadeOut(tween(120))){content()}
}

// 页面入场：按 delay 分层淡入上浮，首页/页首使用
@Composable fun EnterAnim(delay:Int=0,content:@Composable ()->Unit){
 var shown by remember{mutableStateOf(false)}
 LaunchedEffect(Unit){shown=true}
 AnimatedVisibility(visible=shown,enter=fadeIn(tween(340,delay,FastOutSlowInEasing))+slideInVertically(spring(dampingRatio=.85f,stiffness=Spring.StiffnessMediumLow)){it/9}){content()}
}

// 弹簧弹出：小窗/气泡/徽标的出现
@Composable fun SpringIn(modifier:Modifier=Modifier,content:@Composable ()->Unit){
 var shown by remember{mutableStateOf(false)}
 LaunchedEffect(Unit){shown=true}
 AnimatedVisibility(visible=shown,modifier=modifier,
  enter=fadeIn(tween(200))+slideInVertically(spring(dampingRatio=.82f,stiffness=Spring.StiffnessMediumLow)){it/4}+androidx.compose.animation.scaleIn(spring(dampingRatio=.8f,stiffness=Spring.StiffnessMediumLow),.94f),
  exit=fadeOut(tween(140))+slideOutVertically(tween(160)){it/4}){content()}
}

// 呼吸状态点：运行中会话/连接状态
@Composable fun StatusDot(color:Color=Accent,size:Dp=6.dp){
 val t=rememberInfiniteTransition(label="dot")
 val a by t.animateFloat(1f,.2f,infiniteRepeatable(tween(900,easing=FastOutSlowInEasing),RepeatMode.Reverse),label="a")
 Box(Modifier.size(size).background(color.copy(alpha=a),CircleShape))
}

// 录音脉冲环：麦克风/聆听状态的外扩波纹
@Composable fun PulseRing(color:Color=Ember,modifier:Modifier=Modifier){
 val t=rememberInfiniteTransition(label="pulse")
 Box(modifier){
  listOf(0,1).forEach{i->
   val p by t.animateFloat(0f,1f,infiniteRepeatable(tween(1800,delayMillis=i*900,easing=LinearEasing),RepeatMode.Restart),label="pr$i")
   Box(Modifier.matchParentSize().graphicsLayer{scaleX=.62f+p*.55f;scaleY=.62f+p*.55f;alpha=(1f-p)*.45f}.background(color,CircleShape))
  }
 }
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

// 微光骨架：加载时的 shimmer 占位
@Composable fun rememberShimmerBrush():Brush{
 val t=rememberInfiniteTransition(label="shimmer")
 val x by t.animateFloat(0f,1f,infiniteRepeatable(tween(1400,easing=LinearEasing),RepeatMode.Restart),label="shx")
 return Brush.linearGradient(listOf(Track,Color.White,Track),start=Offset(x*700f-250f,0f),end=Offset(x*700f+250f,0f))
}
@Composable fun ShimmerCard(modifier:Modifier=Modifier){
 val b=rememberShimmerBrush()
 Surface(modifier,shape=RoundedCornerShape(Radii.Xl),color=Card,border=BorderStroke(1.dp,Line),shadowElevation=Elev.Card){
  Column(Modifier.padding(Spacing.L)){
   Box(Modifier.fillMaxWidth(.68f).height(14.dp).background(b,RoundedCornerShape(7.dp)))
   Box(Modifier.padding(top=9.dp).fillMaxWidth(.42f).height(11.dp).background(b,RoundedCornerShape(6.dp)))
  }
 }
}
