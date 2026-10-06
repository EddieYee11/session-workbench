package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONObject

/** machines / gaps 是字符串数组，JSONObject.array() 只取对象。 */
private fun JSONObject.goalStrings(key:String):List<String>{
 val raw=optJSONArray(key)?:return emptyList()
 return (0 until raw.length()).mapNotNull{raw.optString(it).takeIf{s->s.isNotBlank()}}
}

private fun goalTierLabel(tier:String)=when(tier){
 "long_term"->"长期方向"
 "active"->"在推进"
 "commitment"->"待办承诺"
 else->"未分级"
}

/** 与现有画像/行动台的关系：new 不标，标了就是提醒「这条不是新东西」。 */
private fun goalRelationLabel(relation:String)=when(relation){
 "existing"->"已有"
 "completed"->"已完成"
 "changed"->"有变化"
 else->""
}

private fun goalProposalTitle(proposal:JSONObject):String{
 val generated=proposal.optString("generated_at").replace('T',' ').take(16)
 val mode=if(proposal.optString("mode")=="weekly")"周" else "日"
 return "目标提案 · $generated · $mode"
}

/**
 * 目标提案：各 agent 会话里提炼出的目标，逐条勾选后落到画像与行动台。
 * 只做审批面：合成与落库都在后端，这里不改内容，只决定哪几条进来。
 */
@Composable fun GoalProposalSection(vm:WorkbenchModel){
 val visible=vm.visibleGoalProposals()
 // 没有待批准、也没有刚批完的，就不占首页版面。
 if(visible.isEmpty())return
 val pending=visible.count{it.isNull("decision")}
 HorizontalDivider(Modifier.padding(top=16.dp,bottom=18.dp),color=Line)
 Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically){
  Text(if(pending>0)"🎯 待批准的目标" else "🎯 目标提案已提交",Modifier.weight(1f),fontSize=18.sp,fontWeight=FontWeight.SemiBold,color=Ink)
  TextButton(onClick={vm.refreshGoalProposalsNow()},enabled=!vm.goalProposalsLoading&&vm.store.token.isNotEmpty()){
   Text(if(vm.goalProposalsLoading)"刷新中" else "刷新",fontSize=Type.Caption)
  }
 }
 Text("从最近 30 天的会话里提炼，只收明确说过的方向与承诺。",fontSize=Type.Caption,lineHeight=18.sp,color=Muted)
 if(!vm.goalProposalsFresh)Text("以下缓存自上次同步，同步后才能批准。",Modifier.padding(top=5.dp),fontSize=Type.Caption,color=AmberText)
 if(vm.goalProposalsError.isNotBlank())Text(vm.goalProposalsError,Modifier.padding(top=5.dp),fontSize=Type.Caption,color=AmberText)
 visible.forEach{proposal->GoalProposalCard(vm,proposal)}
}

@Composable fun GoalProposalCard(vm:WorkbenchModel,proposal:JSONObject){
 val id=proposal.optString("id")
 val entries=proposal.array("items")
 val decided=!proposal.isNull("decision")
 val checked=vm.checkedGoals(id)?:vm.defaultGoalChecked(proposal)
 Surface(Modifier.fillMaxWidth().padding(top=10.dp),shape=RoundedCornerShape(Radii.L),
  color=if(decided)Card else AmberBg,border=BorderStroke(1.dp,if(decided)Line else AmberLine)){
  Column(Modifier.padding(14.dp)){
   Text(goalProposalTitle(proposal),fontSize=Type.Body,fontWeight=FontWeight.SemiBold,color=Ink)
   Text("来源 ${proposal.goalStrings("machines").joinToString(" + ")} · ${entries.size} 条",
    Modifier.padding(top=5.dp),fontSize=Type.Caption,color=Muted)
   if(proposal.goalStrings("gaps").isNotEmpty())Text("本次缺件：${proposal.goalStrings("gaps").joinToString("、")}",
    Modifier.padding(top=5.dp),fontSize=Type.Caption,color=AmberText)
   GoalNotesSection(proposal)
   HorizontalDivider(Modifier.padding(vertical=10.dp),color=if(decided)Line else AmberLine)
   entries.forEach{entry->GoalEntryRow(entry,decided,checked.contains(entry.optString("id"))){
    vm.setGoalChecked(id,if(checked.contains(entry.optString("id"))) checked-entry.optString("id") else checked+entry.optString("id"))
   }}
   GoalSuspectSection(proposal)
   if(decided)GoalReceipt(vm,id,proposal,entries.size)
   else GoalProposalActions(vm,id,entries,checked)
  }
 }
}

/** 一条目标：分级徽章 + 勾选框 + 证据小字；证据可展开逐条核验。 */
@Composable private fun GoalEntryRow(entry:JSONObject,decided:Boolean,on:Boolean,onToggle:()->Unit){
 val entryId=entry.optString("id")
 val evidence=entry.array("evidence")
 var quotes by remember(entryId){mutableStateOf(false)}
 Row(Modifier.fillMaxWidth().padding(top=8.dp).clickable(enabled=!decided,onClick=onToggle),verticalAlignment=Alignment.Top){
  if(!decided)GoalCheckBox(on)
  Column(Modifier.weight(1f).padding(start=if(decided)0.dp else 10.dp)){
   Row(verticalAlignment=Alignment.CenterVertically){
    GoalBadge(goalTierLabel(entry.optString("tier")),ChipBg,Ink)
    val relation=goalRelationLabel(entry.optString("relation"))
    if(relation.isNotBlank())Box(Modifier.padding(start=6.dp)){GoalBadge(relation,Card,Muted)}
    if(entry.optString("confidence")=="medium")Box(Modifier.padding(start=6.dp)){GoalBadge("待确认",Card,AmberText)}
   }
   Text(entry.optString("title"),Modifier.padding(top=5.dp),fontSize=Type.BodySm,fontWeight=FontWeight.SemiBold,color=Ink)
   Text(entry.optString("statement"),Modifier.padding(top=3.dp),fontSize=Type.Caption,lineHeight=18.sp,color=Muted)
   val bits=mutableListOf("证据 ${evidence.size} 条")
   val last=entry.optString("last_seen")
   if(last.isNotBlank())bits+="最近 $last"
   val ref=entry.optString("existing_ref")
   if(ref.isNotBlank())bits+="已有 $ref"
   Text(bits.joinToString(" · "),Modifier.padding(top=4.dp),fontSize=Type.Micro,color=Faint)
   if(evidence.isNotEmpty()){
    TextButton(onClick={quotes=!quotes},contentPadding=PaddingValues(0.dp)){Text(if(quotes)"收起引文" else "查看引文",fontSize=Type.Micro)}
    if(quotes)evidence.forEach{e->Text("· ${e.optString("date")} [${e.optString("source")}] ${e.optString("quote").take(120)}",
     Modifier.padding(top=3.dp),fontSize=Type.Micro,lineHeight=16.sp,color=Muted)}
   }
  }
 }
}

/** 勾选框用方框而非 Material Checkbox：与卡片的中性色一致，不引入主题色。 */
@Composable private fun GoalCheckBox(on:Boolean){
 val shape=RoundedCornerShape(Radii.S)
 Box(Modifier.padding(top=2.dp).size(20.dp).clip(shape).background(if(on)Ink else Card).border(1.dp,if(on)Ink else Line,shape),
  contentAlignment=Alignment.Center){
  if(on)Text("✓",fontSize=Type.Caption,color=Card)
 }
}

@Composable private fun GoalBadge(text:String,bg:androidx.compose.ui.graphics.Color,fg:androidx.compose.ui.graphics.Color){
 Box(Modifier.background(bg,RoundedCornerShape(Radii.S)).border(1.dp,Line,RoundedCornerShape(Radii.S)).padding(horizontal=6.dp,vertical=1.dp)){
  Text(text,fontSize=Type.Micro,color=fg)
 }
}

/** 合成器对分级的自我说明。是审计材料，不是决策信息，默认收起来。 */
@Composable private fun GoalNotesSection(proposal:JSONObject){
 val notes=proposal.optString("notes")
 if(notes.isBlank())return
 var open by remember(proposal.optString("id")){mutableStateOf(false)}
 TextButton(onClick={open=!open},contentPadding=PaddingValues(0.dp)){
  Text(if(open)"收起口径说明" else "口径说明",fontSize=Type.Micro)
 }
 if(open)Text(notes,Modifier.padding(top=3.dp),fontSize=Type.Micro,lineHeight=17.sp,color=Muted)
}

/** 低置信留在这里只读展示：不进勾选，也不落库。 */
@Composable private fun GoalSuspectSection(proposal:JSONObject){
 val suspect=proposal.array("suspect")
 if(suspect.isEmpty())return
 var open by remember(proposal.optString("id")){mutableStateOf(false)}
 TextButton(onClick={open=!open},contentPadding=PaddingValues(0.dp)){
  Text(if(open)"收起存疑 ${suspect.size} 条" else "存疑 ${suspect.size} 条（未提案）",fontSize=Type.Caption)
 }
 if(open)suspect.forEach{s->Column(Modifier.padding(top=4.dp)){
  Text("· ${s.optString("title")}",fontSize=Type.Caption,color=Muted)
  Text(s.optString("why"),Modifier.padding(start=8.dp,top=2.dp),fontSize=Type.Micro,lineHeight=16.sp,color=Faint)
 }}
}

@Composable private fun GoalReceipt(vm:WorkbenchModel,id:String,proposal:JSONObject,count:Int){
 val decision=proposal.optJSONObject("decision")
 val applied=decision?.optJSONObject("applied")
 val approved=decision?.optJSONArray("approved")?.length()?:0
 Text(if(approved>0)"已批准 $approved 条${if(applied!=null)"，共落库 ${applied.optInt("count")} 条" else "，正在落库"}" else "已全部驳回",
  Modifier.padding(top=10.dp),fontSize=Type.Caption,color=Muted)
 if(applied!=null){
  val vault=applied.optJSONArray("vault")?.length()?:0
  val profile=applied.optString("profile")
  Text(listOfNotNull(
   profile.takeIf{it.isNotBlank()}?.let{"画像：${it.substringAfterLast('/')}"},
   "行动台：$vault 个对象",
   applied.optString("backup").takeIf{it.isNotBlank()}?.let{"已备份至 ${it.substringAfterLast('/')}"}).joinToString(" · "),
   Modifier.padding(top=3.dp),fontSize=Type.Micro,lineHeight=16.sp,color=Faint)
 }
 if(vm.goalProposalNoteId==id&&vm.goalProposalNote.isNotBlank())
  Text(vm.goalProposalNote,Modifier.padding(top=6.dp),fontSize=Type.Caption,color=AmberText)
 Text("共 ${count} 条，本卡不会重发。",Modifier.padding(top=5.dp),fontSize=Type.Micro,color=Faint)
}

@Composable private fun GoalProposalActions(vm:WorkbenchModel,id:String,entries:List<JSONObject>,checked:Set<String>){
 val ids=entries.map{it.optString("id")}
 val enabled=vm.goalProposalsFresh&&vm.goalProposalBusy.isBlank()&&vm.store.token.isNotBlank()
 val haptics=rememberComHaptics()
 Row(Modifier.fillMaxWidth().padding(top=12.dp),horizontalArrangement=Arrangement.spacedBy(10.dp)){
  Button(onClick={
   haptics(HapticCue.Commit)
   vm.decideGoalProposal(id,ids.filter{it in checked},ids.filter{it !in checked})
  },enabled=enabled&&checked.isNotEmpty(),modifier=Modifier.weight(1f),shape=Radii.Pill){
   Text(if(vm.goalProposalBusy==id)"正在落库…" else "批准勾选项 ${checked.size}",fontSize=Type.BodySm)
  }
  OutlinedButton(onClick={
   haptics(HapticCue.Reject)
   vm.decideGoalProposal(id,emptyList(),ids)
  },enabled=enabled,modifier=Modifier.weight(1f),shape=Radii.Pill){
   Text("全部驳回",fontSize=Type.BodySm)
  }
 }
 if(checked.isEmpty())Text("高置信的会自动勾上；其余要落库请点条目左侧方框。",
  Modifier.padding(top=6.dp),fontSize=Type.Micro,lineHeight=16.sp,color=Muted)
 if(vm.goalProposalNoteId==id&&vm.goalProposalNote.isNotBlank())
  Text(vm.goalProposalNote,Modifier.padding(top=6.dp),fontSize=Type.Caption,lineHeight=17.sp,color=AmberText)
 if(!vm.goalProposalsFresh)Text("离线记录，同步后才能批准。",Modifier.padding(top=5.dp),fontSize=Type.Caption,color=AmberText)
}
