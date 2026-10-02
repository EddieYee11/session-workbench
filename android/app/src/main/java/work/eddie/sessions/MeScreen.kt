package work.eddie.sessions

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.*
import org.json.JSONArray

private fun loadMemory(prefs:android.content.SharedPreferences)=runCatching{JSONArray(prefs.getString("memory","[]")?:"[]")}.getOrDefault(JSONArray()).let{(0 until it.length()).mapNotNull{idx->it.optString(idx).takeIf{txt->txt.isNotBlank()}}}
private fun saveMemory(prefs:android.content.SharedPreferences,list:List<String>){prefs.edit().putString("memory",JSONArray(list).toString()).apply()}

@Composable fun MeScreen(vm:WorkbenchModel){
 val context=LocalContext.current
 val prefs=vm.store.prefs
 var settings by remember{mutableStateOf(false)}
 var memories by remember{mutableStateOf(loadMemory(prefs))}
 var addMemory by remember{mutableStateOf("")};var addOpen by remember{mutableStateOf(false)}
 var skillLedger by remember{mutableStateOf(prefs.getBoolean("skill_ledger",true))}
 var skillFav by remember{mutableStateOf(prefs.getBoolean("skill_fav",true))}
 var skillVoice by remember{mutableStateOf(prefs.getBoolean("skill_voice",false))}
 var calGranted by remember{mutableStateOf(context.checkSelfPermission(Manifest.permission.READ_CALENDAR)==PackageManager.PERMISSION_GRANTED)}
 val calLauncher=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){calGranted=it}
 Column(Modifier.fillMaxSize().background(Paper).statusBarsPadding()){
  Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal=16.dp).padding(bottom=12.dp)){
   Row(Modifier.padding(top=10.dp,bottom=12.dp),verticalAlignment=Alignment.CenterVertically){
    Box(Modifier.size(52.dp).background(Ink,CircleShape),contentAlignment=Alignment.Center){Text("E",color=Color.White,fontSize=20.sp,fontWeight=FontWeight.Bold)}
    Column(Modifier.weight(1f).padding(start=14.dp)){
     Text("Eddie",fontSize=18.sp,fontWeight=FontWeight.Bold,color=Ink)
     Text(if(vm.connected)"Mac mini · 已连接" else "Mac mini · 未连接",fontSize=12.sp,color=Muted)
    }
    IconButton(onClick={settings=true},modifier=Modifier.size(44.dp).clip(CircleShape).background(Card).border(1.dp,Line,CircleShape)){Icon(Icons.Outlined.Settings,"设置",Modifier.size(20.dp),tint=Ink)}
   }
   SectionHeader("记忆")
   PolishCard{
    Column(Modifier.padding(horizontal=16.dp,vertical=6.dp)){
     if(memories.isEmpty())Text("还没有记忆。记下你的偏好，Agent 会一直记得。",Modifier.padding(vertical=12.dp),fontSize=13.sp,color=Faint)
     memories.forEachIndexed{i,m->
      Row(Modifier.padding(vertical=10.dp),verticalAlignment=Alignment.CenterVertically){
       Text(m,Modifier.weight(1f),fontSize=14.sp,color=Ink)
       IconButton(onClick={val l=memories.toMutableList();l.removeAt(i);memories=l;saveMemory(prefs,l)},modifier=Modifier.size(30.dp)){Icon(Icons.Outlined.DeleteOutline,null,Modifier.size(17.dp),tint=Faint)}
      }
      if(i<memories.size-1)HorizontalDivider(color=Line)
     }
     TextButton(onClick={addOpen=true},modifier=Modifier.fillMaxWidth()){Icon(Icons.Outlined.Add,null,Modifier.size(16.dp));Text("添加一条记忆",Modifier.padding(start=6.dp),fontSize=13.sp)}
    }
   }
   SectionHeader("技能",Modifier.padding(top=16.dp))
   PolishCard{
    Column(Modifier.padding(horizontal=16.dp,vertical=4.dp)){
     SkillRow("记账","语音或输入一句话就记上",skillLedger){skillLedger=it;prefs.edit().putBoolean("skill_ledger",it).apply()}
     HorizontalDivider(color=Line)
     SkillRow("收藏","看到好的内容随时收进来",skillFav){skillFav=it;prefs.edit().putBoolean("skill_fav",it).apply()}
     HorizontalDivider(color=Line)
     SkillRow("语音备忘","说话就记，不用打字",skillVoice){skillVoice=it;prefs.edit().putBoolean("skill_voice",it).apply()}
    }
   }
   SectionHeader("连接",Modifier.padding(top=16.dp))
   PolishCard{
    Column(Modifier.padding(horizontal=16.dp,vertical=4.dp)){
     ConnRow("Mac mini",if(vm.connected)"已连接 · ${vm.store.base.substringAfter("https://").substringBefore("/")}" else "未连接",vm.connected){}
     HorizontalDivider(color=Line)
     ConnRow("手机日历",if(calGranted)"已授权" else "未授权",calGranted){if(!calGranted)calLauncher.launch(Manifest.permission.READ_CALENDAR)}
    }
   }
   Text("Com! v${BuildConfig.VERSION_NAME}",Modifier.padding(top=20.dp).align(Alignment.CenterHorizontally),fontSize=11.sp,color=Faint)
  }
 }
 if(settings)Settings(vm){settings=false}
 if(addOpen)AlertDialog(onDismissRequest={addOpen=false},containerColor=Card,title={Text("添加记忆",fontWeight=FontWeight.SemiBold)},
  text={OutlinedTextField(addMemory,{addMemory=it},Modifier.fillMaxWidth(),placeholder={Text("比如：周末不安排工作")},shape=RoundedCornerShape(Radii.M))},
  confirmButton={Button(onClick={if(addMemory.isNotBlank()){val l=memories+addMemory.trim();memories=l;saveMemory(prefs,l)};addMemory="";addOpen=false},shape=RoundedCornerShape(50),colors=ButtonDefaults.buttonColors(containerColor=Ember)){Text("保存")}},
  dismissButton={TextButton(onClick={addOpen=false}){Text("取消")}})
}

@Composable fun SkillRow(name:String,desc:String,on:Boolean,change:(Boolean)->Unit){
 Row(Modifier.padding(vertical=10.dp),verticalAlignment=Alignment.CenterVertically){
  Column(Modifier.weight(1f)){Text(name,fontSize=14.sp,fontWeight=FontWeight.Medium,color=Ink);Text(desc,fontSize=12.sp,color=Muted)}
  Switch(on,change,colors=SwitchDefaults.colors(checkedTrackColor=Ember))
 }
}

@Composable fun ConnRow(name:String,status:String,ok:Boolean,click:()->Unit){
 Row(Modifier.clickable(onClick=click).padding(vertical=12.dp),verticalAlignment=Alignment.CenterVertically){
  Text(name,Modifier.weight(1f),fontSize=14.sp,color=Ink)
  Box(Modifier.background(if(ok)PiSoft else ChipBg,RoundedCornerShape(50)).padding(horizontal=10.dp,vertical=4.dp)){Text(status,fontSize=11.sp,fontWeight=FontWeight.Medium,color=if(ok)PiGreen else Muted)}
 }
}
