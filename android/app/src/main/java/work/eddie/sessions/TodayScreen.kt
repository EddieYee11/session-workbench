package work.eddie.sessions

import android.Manifest
import android.content.ContentUris
import android.content.ContentResolver
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.*

data class CalEvent(val title:String,val begin:Long,val end:Long,val location:String)

fun loadTodayEvents(cr:ContentResolver):List<CalEvent>{
 val cal=Calendar.getInstance().apply{set(Calendar.HOUR_OF_DAY,0);set(Calendar.MINUTE,0);set(Calendar.SECOND,0);set(Calendar.MILLISECOND,0)}
 val start=cal.timeInMillis;val end=start+86400000L
 val b=CalendarContract.Instances.CONTENT_URI.buildUpon()
 ContentUris.appendId(b,start);ContentUris.appendId(b,end)
 return runCatching{
  cr.query(b.build(),arrayOf(CalendarContract.Instances.TITLE,CalendarContract.Instances.BEGIN,CalendarContract.Instances.END,CalendarContract.Instances.EVENT_LOCATION),
   null,null,"${CalendarContract.Instances.BEGIN} ASC")?.use{c->
   buildList{while(c.moveToNext())add(CalEvent(c.getString(0)?.ifBlank{"（无标题）"}?:"（无标题）",c.getLong(1),c.getLong(2),c.getString(3)?:""))}
  }?:emptyList()
 }.getOrDefault(emptyList())
}

private fun fmtTime(ts:Long)=SimpleDateFormat("HH:mm",Locale.CHINA).format(Date(ts))

@Composable fun TodayScreen(vm:WorkbenchModel){
 val context=LocalContext.current
 val ledger=remember{LedgerStore(context)}
 var entries by remember{mutableStateOf(ledger.entries())}
 var granted by remember{mutableStateOf(context.checkSelfPermission(Manifest.permission.READ_CALENDAR)==PackageManager.PERMISSION_GRANTED)}
 val launcher=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){granted=it}
 var events by remember{mutableStateOf<List<CalEvent>?>(null)}
 LaunchedEffect(granted){events=if(granted)withContext(Dispatchers.IO){loadTodayEvents(context.contentResolver)}else null}
 var addOpen by remember{mutableStateOf(false)}
 val dateStr=SimpleDateFormat("M月d日 EEEE",Locale.CHINA).format(Date())
 val todayOut=entries.let{ledger.todayOut()}
 val running=remember(vm.allRows){vm.allRows.count{it.optBoolean("managed")&&it.optString("status")=="running"}}
 val waiting=remember(vm.allRows){vm.allRows.count{it.optBoolean("managed")&&it.optString("status")=="waiting"}}
 val evCount=events?.size?:0
 val brief=buildString{
  append(if(evCount==0)"今天没有日程" else "今天有 $evCount 个日程")
  append(" · 今日支出 ${money(todayOut)}")
  if(waiting>0)append(" · $waiting 个任务等你回应") else if(running>0)append(" · $running 个任务运行中")
 }
 Column(Modifier.fillMaxSize().background(Paper).statusBarsPadding()){
  Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal=16.dp).padding(bottom=12.dp)){
   Text(dateStr,Modifier.padding(top=10.dp,bottom=10.dp),fontSize=20.sp,fontWeight=FontWeight.Bold,letterSpacing=(-.5).sp,color=Ink)
   // 摘要
   Surface(shape=RoundedCornerShape(Radii.Xl),color=Ink,shadowElevation=Elev.Card){
    Row(Modifier.padding(16.dp),verticalAlignment=Alignment.CenterVertically){
     Box(Modifier.size(40.dp).background(Color.White.copy(alpha=.14f),androidx.compose.foundation.shape.CircleShape),contentAlignment=Alignment.Center){Text("今",color=Color.White,fontSize=17.sp,fontWeight=FontWeight.Bold)}
     Text(brief,Modifier.padding(start=12.dp),fontSize=14.sp,lineHeight=21.sp,color=Color.White)
    }
   }
   // 日历
   SectionHeader("日历",Modifier.padding(top=18.dp,bottom=2.dp))
   when{
    !granted->PolishCard(onClick={launcher.launch(Manifest.permission.READ_CALENDAR)}){
     Row(Modifier.padding(16.dp),verticalAlignment=Alignment.CenterVertically){
      Icon(Icons.Outlined.CalendarMonth,null,Modifier.size(22.dp),tint=Muted)
      Column(Modifier.weight(1f).padding(start=12.dp)){Text("读取手机日历",fontSize=14.sp,fontWeight=FontWeight.Medium,color=Ink);Text("授权后显示今日日程（Google 日历同步到手机即可）",fontSize=12.sp,color=Muted)}
      Icon(Icons.Outlined.ChevronRight,null,tint=Faint)
     }}
    events==null->PolishCard{Box(Modifier.padding(20.dp)){ThinkingDots()}}
    events!!.isEmpty()->PolishCard{Text("今天没有安排，好好休息。",Modifier.padding(16.dp),fontSize=14.sp,color=Muted)}
    else->PolishCard{Column(Modifier.padding(horizontal=4.dp,vertical=6.dp)){events!!.forEach{e->
     Row(Modifier.padding(horizontal=12.dp,vertical=10.dp),verticalAlignment=Alignment.CenterVertically){
      Text(fmtTime(e.begin),Modifier.width(48.dp),fontSize=12.sp,color=Muted,fontWeight=FontWeight.Medium)
      Box(Modifier.width(3.dp).height(34.dp).background(Ember,RoundedCornerShape(2.dp)))
      Column(Modifier.weight(1f).padding(start=12.dp)){
       Text(e.title,fontSize=14.sp,fontWeight=FontWeight.Medium,color=Ink,maxLines=1,overflow=TextOverflow.Ellipsis)
       if(e.location.isNotBlank())Text(e.location,fontSize=12.sp,color=Muted,maxLines=1,overflow=TextOverflow.Ellipsis)
      }
     }}}}
   }
   // 记账
   Row(Modifier.padding(top=18.dp,bottom=2.dp),verticalAlignment=Alignment.CenterVertically){
    SectionHeader("记账",Modifier.weight(1f))
    TextButton(onClick={addOpen=true}){Icon(Icons.Outlined.Add,null,Modifier.size(16.dp));Text("记一笔",Modifier.padding(start=4.dp),fontSize=13.sp)}
   }
   PolishCard{
    Column(Modifier.padding(16.dp)){
     Row(verticalAlignment=Alignment.Bottom){
      Text("今日支出",fontSize=12.sp,color=Muted)
      Spacer(Modifier.weight(1f))
      Text("本月 ${money(ledger.monthOut())}",fontSize=12.sp,color=Muted)
     }
     Text(money(todayOut),Modifier.padding(top=2.dp),fontSize=30.sp,fontWeight=FontWeight.Bold,letterSpacing=(-.5).sp,color=Ink)
     if(entries.isNotEmpty()){
      HorizontalDivider(Modifier.padding(vertical=10.dp),color=Line)
      entries.take(5).forEach{e->
       Row(Modifier.padding(vertical=7.dp),verticalAlignment=Alignment.CenterVertically){
        Box(Modifier.size(34.dp).background(ChipBg,androidx.compose.foundation.shape.CircleShape),contentAlignment=Alignment.Center){Text(e.category.first().toString(),fontSize=14.sp,color=Muted)}
        Column(Modifier.weight(1f).padding(start=10.dp)){
         Text(if(e.note.isNotBlank())e.note else e.category,fontSize=14.sp,color=Ink,maxLines=1,overflow=TextOverflow.Ellipsis)
         Text("${e.category} · ${fmtTime(e.ts)}",fontSize=11.sp,color=Faint)
        }
        Text((if(e.kind=="in")"+" else "-")+money(e.amount).removePrefix("¥"),fontSize=14.sp,fontWeight=FontWeight.SemiBold,color=if(e.kind=="in")PiGreen else Ink)
       }
      }
     }else Text("还没有记录，点右上「记一笔」开始。",Modifier.padding(top=8.dp),fontSize=13.sp,color=Faint)
    }
   }
   // Agent 动态
   SectionHeader("Agent 动态",Modifier.padding(top=18.dp,bottom=2.dp))
   PolishCard{
    Column(Modifier.padding(horizontal=16.dp,vertical=8.dp)){
     if(!vm.connected)Row(Modifier.padding(vertical=10.dp),verticalAlignment=Alignment.CenterVertically){StatusDot(Faint);Text("Mac mini 未连接",Modifier.padding(start=10.dp),fontSize=14.sp,color=Muted)}
     else{
      if(running>0)Row(Modifier.padding(vertical=10.dp),verticalAlignment=Alignment.CenterVertically){StatusDot(Ember);Text("$running 个任务运行中",Modifier.padding(start=10.dp),fontSize=14.sp,color=Ink)}
      if(waiting>0)Row(Modifier.padding(vertical=10.dp),verticalAlignment=Alignment.CenterVertically){StatusDot(AmberText);Text("$waiting 个任务等你回应",Modifier.padding(start=10.dp),fontSize=14.sp,color=AmberText)}
      if(running==0&&waiting==0)Row(Modifier.padding(vertical=10.dp),verticalAlignment=Alignment.CenterVertically){StatusDot(PiGreen);Text("一切安静，没有进行中的任务",Modifier.padding(start=10.dp),fontSize=14.sp,color=Muted)}
     }
    }
   }
   Spacer(Modifier.height(8.dp))
  }
 }
 if(addOpen)LedgerAddDialog({addOpen=false},{amount,cat,note->ledger.add(amount,cat,note);entries=ledger.entries();addOpen=false})
}

@OptIn(ExperimentalLayoutApi::class)
@Composable fun LedgerAddDialog(dismiss:()->Unit,save:(Double,String,String)->Unit){
 var amount by remember{mutableStateOf("")};var category by remember{mutableStateOf("餐饮")};var note by remember{mutableStateOf("")}
 val value=amount.toDoubleOrNull()
 AlertDialog(onDismissRequest=dismiss,containerColor=Card,title={Text("记一笔",fontWeight=FontWeight.SemiBold)},
  text={Column{
   OutlinedTextField(amount,{amount=it.filter{c->c.isDigit()||c=='.'}},Modifier.fillMaxWidth(),label={Text("金额")},prefix={Text("¥")},singleLine=true,keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Decimal),shape=RoundedCornerShape(Radii.M))
   Text("分类",Modifier.padding(top=12.dp,bottom=6.dp),fontSize=12.sp,color=Muted)
   FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
    LedgerCategories.forEach{c->
     FilterChip(category==c,{category=c},label={Text(c,fontSize=13.sp)},colors=FilterChipDefaults.filterChipColors(selectedContainerColor=Ink,selectedLabelColor=Color.White))
    }}
   OutlinedTextField(note,{note=it},Modifier.fillMaxWidth().padding(top=12.dp),label={Text("备注（可选）")},singleLine=true,shape=RoundedCornerShape(Radii.M))
  }},
  confirmButton={Button(onClick={if(value!=null&&value>0)save(value,category,note)},enabled=value!=null&&value>0,shape=RoundedCornerShape(50),colors=ButtonDefaults.buttonColors(containerColor=Ember)){Text("保存")}},
  dismissButton={TextButton(onClick=dismiss){Text("取消")}})
}
