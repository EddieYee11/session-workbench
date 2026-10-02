package work.eddie.sessions

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.*
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
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

// 中性表面承载内容，角色本身和少量状态色承担个性。
// 暖白底（向 Muse 的视觉语言对齐：画布 90% 中性，点缀色只出现在可交互处）
val Ink=Color(0xFF141414);val Paper=Color(0xFFFAFAF8);val SidebarBg=Color(0xFFF5F5F5)
val Card=Color(0xFFFFFFFF);val Muted=Color(0xFF686868);val Faint=Color(0xFF909090)
val Line=Color(0xFFEAEAEA);val Track=Color(0xFFEDEDED);val ChipBg=Color(0xFFF1F1F1)
val UserBubble=Color(0xFFECECEC);val ToolSurface=Color(0xFFF3F3F3)
val HermesUserBubble=Color(0xFFE3EEE7);val HermesAssistantBubble=Color(0xFFF0F0ED)
val Accent=Ink;val AccentSoft=Color(0xFFEDEDED);val AccentInk=Ink
val CompanionCoral=Color(0xFFC57665);val CompanionBlue=Color(0xFF5F8794)
val CompanionGlow=Color(0xFFE2EFF0);val CompanionBlush=Color(0xFFF8EAE3)
val PiGreen=Color(0xFF396C55);val PiSoft=Color(0xFFE7F2EC)
val AmberBg=Color(0xFFFFF7E8);val AmberLine=Color(0xFFF0E0B0);val AmberText=Color(0xFF8A6D1D)
val ApprovalBg=AmberBg
val Danger=Color(0xFFB24A3D);val Success=PiGreen

// 保留少量强调色，避免把整页背景染成角色色。
val WashTop=Paper;val WashMid=Paper;val WashBottom=Paper
// 暖赭仅用于局部主操作与状态。
val Ember=Color(0xFF333333);val EmberDeep=Color(0xFF333333);val EmberSoft=Color(0xFFEDEDED)
// 点缀金：状态徽标与高光
val Gold=Color(0xFFC99A3C);val GoldSoft=Color(0xFFFAF0DA)

val Palette=lightColorScheme(
 primary=Ink,onPrimary=Color.White,primaryContainer=AccentSoft,onPrimaryContainer=Ink,
 secondary=Muted,secondaryContainer=ChipBg,onSecondaryContainer=Ink,
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
 val Card=0.dp;val Raised=2.dp;val Sheet=8.dp
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

// 只有悬浮层使用中性投影；普通内容卡片靠表面与边界区分。
fun Modifier.softShadow(elevation:Dp,shape:Shape=RoundedCornerShape(Radii.Xl),spot:Color=Color(0x20000000),ambient:Color=Color(0x10000000))=this.shadow(elevation,shape,clip=false,spotColor=spot,ambientColor=ambient)

// 保留入口名称，页面背景改为稳定的单层表面。
@Composable fun WashBackground(modifier:Modifier=Modifier,content:@Composable ()->Unit){
 Box(modifier.background(Paper)){content()}
}

// 毛玻璃底栏：半透明暖白 + 顶部细线；不用实时高斯模糊以保性能
@Composable fun FrostedBar(modifier:Modifier=Modifier,content:@Composable ()->Unit){
 Column(modifier.background(Paper.copy(alpha=.88f))){
  Box(Modifier.fillMaxWidth().height(.5.dp).background(Line))
  content()
 }
}

// 统一卡片：白底和轻描边，无装饰性投影。
@Composable fun PolishCard(modifier:Modifier=Modifier,radius:Dp=Radii.Xl,onClick:(()->Unit)?=null,content:@Composable ()->Unit){
 if(onClick!=null)Surface(onClick=onClick,modifier=modifier,shape=RoundedCornerShape(radius),color=Card,border=BorderStroke(1.dp,Line),shadowElevation=Elev.Card){content()}
 else Surface(modifier=modifier,shape=RoundedCornerShape(radius),color=Card,border=BorderStroke(1.dp,Line),shadowElevation=Elev.Card){content()}
}

// 焦点会话沿用同一表面语言，点击使用原生涟漪和轻按压。
@Composable fun HeroCard(modifier:Modifier=Modifier,onClick:(()->Unit)?=null,content:@Composable ()->Unit){
 val (press,pressMod)=rememberPress()
 if(onClick!=null)Surface(onClick=onClick,modifier=modifier.then(pressMod),interactionSource=press,shape=RoundedCornerShape(Radii.Xxl),color=Card,border=BorderStroke(1.dp,Line),shadowElevation=0.dp){content()}
 else Surface(modifier=modifier,shape=RoundedCornerShape(Radii.Xxl),color=Card,border=BorderStroke(1.dp,Line),shadowElevation=0.dp){content()}
}

// 空状态：图标 + 标题 + 提示，居中；用于列表无内容与无搜索结果
@Composable fun EmptyState(icon:ImageVector,title:String,hint:String){
 var shown by remember{mutableStateOf(false)}
 LaunchedEffect(Unit){shown=true}
 AnimatedVisibility(visible=shown,enter=fadeIn(tween(160))){
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
 val Press=spring<Float>(dampingRatio=.95f,stiffness=1400f)
 val Pop=spring<Float>(dampingRatio=.72f,stiffness=Spring.StiffnessMediumLow)
 val Fade=tween<Float>(180,easing=FastOutSlowInEasing)
 val Slide=spring<IntOffset>(dampingRatio=.9f,stiffness=Spring.StiffnessMedium)
 val Tint=tween<Color>(200,easing=FastOutSlowInEasing)
 val Glide=spring<Dp>(dampingRatio=.88f,stiffness=Spring.StiffnessMedium)
 val Resize=spring<IntSize>(dampingRatio=.9f,stiffness=Spring.StiffnessMedium)
 // 次要面板少量错开即可，不让用户等列表逐项出现。
 fun staggerDelay(index:Int)=(index.coerceIn(0,3)*20)
}

// 普通控件按压保持克制；角色切换的物理弹簧由角色组件独立控制。
@Composable fun rememberPress(scaleTo:Float=.97f):Pair<MutableInteractionSource,Modifier>{
 val src=remember{MutableInteractionSource()}
 val pressed by src.collectIsPressedAsState()
 val scale by animateFloatAsState(if(pressed)scaleTo else 1f,Motion.Press,label="pressScale")
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
  enter=fadeIn(tween(180,Motion.staggerDelay(index),FastOutSlowInEasing))+slideInVertically(Motion.Slide){it/24},
  exit=fadeOut(tween(120))){content()}
}

// 页面入场：按 delay 分层淡入上浮，首页/页首使用
@Composable fun EnterAnim(delay:Int=0,content:@Composable ()->Unit){
 var shown by remember{mutableStateOf(false)}
 LaunchedEffect(Unit){shown=true}
 AnimatedVisibility(visible=shown,enter=fadeIn(tween(180,delay.coerceIn(0,60),FastOutSlowInEasing))+slideInVertically(Motion.Slide){it/24}){content()}
}

// 弹簧弹出：小窗/气泡/徽标的出现
@Composable fun SpringIn(modifier:Modifier=Modifier,content:@Composable ()->Unit){
 var shown by remember{mutableStateOf(false)}
 LaunchedEffect(Unit){shown=true}
 AnimatedVisibility(visible=shown,modifier=modifier,
  enter=fadeIn(tween(180))+slideInVertically(Motion.Slide){it/12}+androidx.compose.animation.scaleIn(spring(dampingRatio=.95f,stiffness=Spring.StiffnessMedium),.98f),
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
