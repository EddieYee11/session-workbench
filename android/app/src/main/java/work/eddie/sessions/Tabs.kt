package work.eddie.sessions

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.*
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.*
import org.json.JSONObject

private data class Tab(val label:String,val icon:ImageVector)

@Composable fun MainTabs(vm:WorkbenchModel,quick:String,clearQuick:()->Unit){
 var tab by rememberSaveable{mutableStateOf(0)}
 val tabs=listOf(Tab("聊天",Icons.Outlined.ChatBubbleOutline),Tab("今日",Icons.Outlined.WbSunny),Tab("任务",Icons.Outlined.Checklist),Tab("我的",Icons.Outlined.PersonOutline))
 // 键盘弹起时收起页签栏，给输入框让位
 val imeOpen=WindowInsets.ime.getBottom(LocalDensity.current)>0
 val openSession:(JSONObject)->Unit={s->vm.open(s);tab=0}
 Box(Modifier.fillMaxSize()){
  Box(Modifier.fillMaxSize().padding(bottom=if(imeOpen)0.dp else 96.dp)){
   when(tab){
    0->Workbench(vm,quick,clearQuick)
    1->TodayScreen(vm)
    2->TasksScreen(vm,openSession)
    3->MeScreen(vm)
   }
  }
  AnimatedVisibility(!imeOpen,Modifier.align(Alignment.BottomCenter),
   enter=fadeIn(tween(180))+slideInVertically(tween(220)){it/2},exit=fadeOut(tween(120))+slideOutVertically(tween(160)){it/2}){
   FloatingTabBar(tabs,tab){tab=it}
  }
 }
}

@Composable fun FloatingTabBar(tabs:List<Tab>,selected:Int,select:(Int)->Unit){
 Surface(Modifier.navigationBarsPadding().padding(bottom=10.dp),shape=RoundedCornerShape(50),color=Card,border=BorderStroke(1.dp,Line),shadowElevation=8.dp){
  Row(Modifier.padding(horizontal=8.dp,vertical=6.dp),horizontalArrangement=Arrangement.spacedBy(2.dp)){
   tabs.forEachIndexed{i,t->
    val on=i==selected
    val bg by animateColorAsState(if(on)Ink else Color.Transparent,tween(180),label="tab背景")
    val fg=if(on)Color.White else Muted
    Row(Modifier.clip(RoundedCornerShape(50)).background(bg).clickable{select(i)}.padding(horizontal=15.dp,vertical=10.dp),verticalAlignment=Alignment.CenterVertically){
     Icon(t.icon,t.label,Modifier.size(20.dp),tint=fg)
     AnimatedVisibility(on,enter=expandHorizontally(tween(180))+fadeIn(tween(120)),exit=shrinkHorizontally(tween(140))+fadeOut(tween(100))){
      Text(t.label,Modifier.padding(start=6.dp),fontSize=13.sp,fontWeight=FontWeight.SemiBold,color=fg)
     }
    }
   }
  }
 }
}
