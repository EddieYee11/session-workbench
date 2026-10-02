package work.eddie.sessions

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import org.json.JSONObject

@Composable fun TasksScreen(vm:WorkbenchModel,open:(JSONObject)->Unit){
 val working=remember(vm.allRows){vm.allRows.filter{it.optBoolean("managed")&&it.optString("status")!="ended"}
  .sortedWith(compareByDescending<JSONObject>{it.optString("status")=="waiting"}.thenByDescending{it.optDouble("updated")})}
 val recent=remember(vm.allRows,working){val ids=working.map{it.getString("id")}.toSet();vm.allRows.filter{!ids.contains(it.getString("id"))&&it.optInt("archived")==0}.sortedByDescending{it.optDouble("updated")}.take(20)}
 Column(Modifier.fillMaxSize().background(Paper).statusBarsPadding()){
  Text("任务",Modifier.padding(horizontal=16.dp).padding(top=10.dp,bottom=6.dp),fontSize=20.sp,fontWeight=FontWeight.Bold,letterSpacing=(-.5).sp,color=Ink)
  LazyColumn(Modifier.weight(1f).fillMaxWidth(),contentPadding=PaddingValues(start=16.dp,top=4.dp,end=16.dp,bottom=12.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
   if(working.isNotEmpty()){
    item{SectionHeader("进行中 · ${working.size}")}
    items(working,key={it.getString("id")}){s->TaskRow(vm,s){open(s)}}
   }
   if(recent.isNotEmpty()){
    item{SectionHeader("最近会话")}
    items(recent,key={it.getString("id")}){s->TaskRow(vm,s){open(s)}}
   }
   if(working.isEmpty()&&recent.isEmpty())item{
    EmptyState(Icons.Outlined.Checklist,"还没有任务","去「聊天」页交给 Pi 或 Codex 一件事，它会出现在这里")
   }
  }
 }
}

@Composable fun TaskRow(vm:WorkbenchModel,s:JSONObject,open:()->Unit){
 val status=s.optString("status");val agent=s.optString("agent")
 val (press,pressMod)=rememberPress(.98f)
 Surface(onClick=open,modifier=Modifier.fillMaxWidth().then(pressMod),shape=RoundedCornerShape(Radii.Xl),color=Card,border=BorderStroke(1.dp,Line),shadowElevation=Elev.Card,interactionSource=press){
  Row(Modifier.padding(14.dp),verticalAlignment=Alignment.CenterVertically){
   Box(Modifier.size(40.dp).clip(RoundedCornerShape(Radii.M)).background(if(agent=="pi")PiSoft else AccentSoft),contentAlignment=Alignment.Center){
    when(status){
     "running"->StatusDot(Ember,8.dp)
     "waiting"->Icon(Icons.Outlined.ChatBubbleOutline,null,Modifier.size(18.dp),tint=AmberText)
     else->Icon(if(agent=="pi")Icons.Outlined.Spa else Icons.Outlined.Pets,null,Modifier.size(18.dp),tint=if(agent=="pi")PiGreen else EmberDeep)
    }
   }
   Column(Modifier.weight(1f).padding(horizontal=12.dp)){
    Text(s.optString("display_title").ifBlank{"新会话"},fontSize=14.sp,fontWeight=FontWeight.SemiBold,color=Ink,maxLines=1,overflow=TextOverflow.Ellipsis)
    Text("${if(agent=="pi")"Pi" else "Codex"} · ${statusLabel(status)} · ${relTime(s.optDouble("updated"))}",Modifier.padding(top=3.dp),fontSize=11.sp,color=Muted,maxLines=1,overflow=TextOverflow.Ellipsis)
   }
   Icon(Icons.Outlined.ChevronRight,null,Modifier.size(18.dp),tint=Faint)
  }
 }
}
