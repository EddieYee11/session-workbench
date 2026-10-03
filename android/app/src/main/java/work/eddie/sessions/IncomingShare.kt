package work.eddie.sessions

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun IncomingShareSheet(vm:WorkbenchModel){
 val shared=vm.incomingShare.optString("text")
 var content by remember(shared){mutableStateOf(shared)}
 var note by remember(shared){mutableStateOf("")}
 var task by remember(shared){mutableStateOf("")}
 val tasks=vm.taskLedger.array("items").filter{it.optString("status") in setOf("running","waiting","queued","paused")}
 val choices=tasks.associateBy{it.optString("title")+" · "+it.optString("id").takeLast(6)}
 val message=listOf(note.trim(),content.trim()).filter{it.isNotBlank()}.joinToString("\n\n")
 ModalBottomSheet(onDismissRequest={vm.clearShare()},containerColor=Paper,sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true)){
  Column(Modifier.fillMaxWidth().padding(horizontal=20.dp).padding(bottom=28.dp)){
   Text("交给 Com!",fontSize=Type.SheetTitle,color=Ink)
   Text("来源：${vm.incomingShare.optString("source").ifBlank{"Android 分享"}}",Modifier.padding(vertical=8.dp),fontSize=Type.Caption,color=Muted)
   OutlinedTextField(content,{content=it},label={Text("分享内容")},modifier=Modifier.fillMaxWidth().heightIn(max=240.dp),maxLines=8)
   OutlinedTextField(note,{note=it},label={Text("补充说明")},modifier=Modifier.fillMaxWidth().padding(top=8.dp),maxLines=3)
   Choice(if(task.isBlank())"主对话" else tasks.firstOrNull{it.optString("id")==task}?.optString("title").orEmpty(),listOf("主对话")+choices.keys){chosen->task=choices[chosen]?.optString("id").orEmpty()}
   Text(if(task.isBlank())"先放入草稿，检查后再发送。" else "将作为所选任务的补充要求发送。",fontSize=Type.Caption,color=Muted)
   Button(onClick={
    if(task.isBlank()){
     vm.updateHermesDraft(listOf(vm.hermesDraft.trim(),message).filter{it.isNotBlank()}.joinToString("\n\n"));vm.externalHermesRoute++
    }else vm.taskCommand(task,message)
    vm.clearShare()
   },enabled=message.isNotBlank()&&(task.isBlank()||vm.taskLedgerFresh&&vm.taskControlBusy.isBlank()&&tasks.any{it.optString("id")==task})){
    Text(if(task.isBlank())"放入主对话草稿" else "发送到所选任务")
   }
   TextButton(onClick={vm.clearShare()}){Text("取消")}
  }
 }
}
