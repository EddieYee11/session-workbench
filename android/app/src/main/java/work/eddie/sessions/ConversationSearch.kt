package work.eddie.sessions

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import org.json.JSONObject

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun ConversationSearchSheet(vm:WorkbenchModel,dismiss:()->Unit){
 var query by remember{mutableStateOf("")}
 var date by remember{mutableStateOf("")}
 var results by remember{mutableStateOf(emptyList<JSONObject>())}
 var error by remember{mutableStateOf("")}
 var loading by remember{mutableStateOf(false)}
 LaunchedEffect(query,date){
  results=emptyList();error=""
  if(query.isBlank()&&date.isBlank())return@LaunchedEffect
  loading=true
  try{delay(350);results=vm.store.request("/personal/search?q=${vm.enc(query)}&date=${vm.enc(date)}").array("items")}
  catch(e:CancellationException){throw e}
  catch(e:Exception){error=e.message?:"搜索暂不可用"}
  finally{loading=false}
 }
 ModalBottomSheet(onDismissRequest=dismiss,containerColor=Paper,sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true)){
  Column(Modifier.fillMaxWidth().fillMaxHeight(.85f).padding(horizontal=20.dp)){
   Text("找回对话",fontSize=Type.Section,color=Ink)
   OutlinedTextField(query,{query=it},label={Text("搜索主对话、任务和成果")},modifier=Modifier.fillMaxWidth(),singleLine=true)
   OutlinedTextField(date,{date=it},label={Text("按日期定位（YYYY-MM-DD）")},modifier=Modifier.fillMaxWidth().padding(top=8.dp),singleLine=true)
   if(loading)LinearProgressIndicator(Modifier.fillMaxWidth().padding(top=10.dp))
   if(error.isNotBlank())Text(error,Modifier.padding(top=8.dp),fontSize=Type.Caption,color=AmberText)
   if(!loading&&error.isBlank()&&(query.isNotBlank()||date.isNotBlank())&&results.isEmpty())Text("当前检索范围内没有匹配消息",Modifier.padding(top=12.dp),fontSize=Type.Caption,color=Muted)
   LazyColumn(Modifier.weight(1f)){
    items(results,key={it.optString("id")}){item->
     Column(Modifier.fillMaxWidth().clickable{when(item.optString("kind")){
      "task"->{vm.refreshWorkProposalsNow();vm.openTaskDetail(item.optString("id"));dismiss()}
      "artifact"->Unit
      else->{vm.locateHermesMessage(item.optString("id"));dismiss()}
     }}.padding(vertical=14.dp)){
      Text("${item.optString("source")} · ${relTime(item.optDouble("created_at"))}",fontSize=Type.Caption,color=Muted)
      if(item.optString("kind")=="artifact")ArtifactCards(listOf(item)) else Text(item.optString("text"),Modifier.padding(top=4.dp),fontSize=Type.BodySm,color=Ink,maxLines=5)
     }
     HorizontalDivider(color=Line)
    }
   }
  }
 }
}
