package work.eddie.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// 参考图（今天 / 记忆）的设计语汇：无描边大圆角卡、圆形图标徽标、元信息堆叠、
// 统计瓦片、纯文字分组标题、悬浮胶囊。只借形态与排版，配色仍走 Com! 自己的暖中性调。

val SoftRadius=28.dp

/** 无描边大圆角卡：参考图里所有内容卡的统一外壳。 */
@Composable fun SoftCard(modifier:Modifier=Modifier,radius:Dp=SoftRadius,onClick:(()->Unit)?=null,padding:PaddingValues=PaddingValues(20.dp),content:@Composable ColumnScope.()->Unit){
 val shape=RoundedCornerShape(radius)
 val body:@Composable ()->Unit={Column(Modifier.padding(padding),content=content)}
 if(onClick!=null)Surface(onClick=onClick,modifier=modifier,shape=shape,color=Card){body()}
 else Surface(modifier=modifier,shape=shape,color=Card){body()}
}

/** 圆形图标徽标：实心色底 + 白色图标，对应参考图分类卡左上角的图标。 */
@Composable fun IconBadge(icon:ImageVector,tint:Color,label:String?=null,size:Dp=44.dp,iconSize:Dp=22.dp){
 Box(Modifier.size(size).background(tint,CircleShape),contentAlignment=Alignment.Center){
  Icon(icon,label,Modifier.size(iconSize),tint=Color.White)
 }
}

/** 统计瓦片：图标在上、数值在下，用于分类卡内的 2×2 网格。 */
@Composable fun StatTile(icon:ImageVector,value:String,tint:Color,modifier:Modifier=Modifier,minHeight:Dp=74.dp){
 Surface(modifier,shape=RoundedCornerShape(Radii.L),color=ToolSurface){
  Column(Modifier.fillMaxWidth().heightIn(min=minHeight).padding(vertical=10.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.Center){
   Icon(icon,null,Modifier.size(17.dp),tint=tint)
   Text(value,Modifier.padding(top=5.dp),fontSize=Type.BodySm,fontWeight=FontWeight.Medium,color=Ink,maxLines=1,overflow=TextOverflow.Ellipsis)
  }
 }
}

/** 纯文字分组标题，对应参考图的「全部」。 */
@Composable fun SoftSectionHeader(text:String,modifier:Modifier=Modifier){
 Text(text,modifier,fontSize=20.sp,fontWeight=FontWeight.SemiBold,color=Ink)
}

/** 悬浮胶囊：白底 + 图标 + 文案 + 箭头，压在 composer 之上。 */
@Composable fun FloatingPill(text:String,onClick:()->Unit,modifier:Modifier=Modifier,leading:ImageVector?=null,leadingTint:Color=CompanionCoral){
 val (press,pressMod)=rememberPress(.97f)
 Surface(onClick=onClick,modifier=modifier.then(pressMod),shape=Radii.Pill,color=Card,shadowElevation=Elev.Sheet,interactionSource=press){
  Row(Modifier.padding(start=if(leading==null)18.dp else 7.dp,top=if(leading==null)10.dp else 7.dp,end=14.dp,bottom=if(leading==null)10.dp else 7.dp),verticalAlignment=Alignment.CenterVertically){
   if(leading!=null){
    Box(Modifier.size(26.dp).background(leadingTint,CircleShape),contentAlignment=Alignment.Center){
     Icon(leading,null,Modifier.size(15.dp),tint=Color.White)
    }
   }
   Text(text,Modifier.padding(start=if(leading==null)0.dp else 9.dp),fontSize=Type.BodySm,fontWeight=FontWeight.Medium,color=Ink,maxLines=1,overflow=TextOverflow.Ellipsis)
   Icon(Icons.Outlined.ChevronRight,null,Modifier.padding(start=4.dp).size(17.dp),tint=Muted)
  }
 }
}
