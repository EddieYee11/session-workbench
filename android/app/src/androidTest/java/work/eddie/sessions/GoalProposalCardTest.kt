package work.eddie.sessions

import android.app.Application
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** 只渲染卡片本身，不联网、不落库：批准路径已由后端 curl 验过。 */
class GoalProposalCardTest {
 @get:Rule val ui=createComposeRule()

 private fun entry(id:String,tier:String,relation:String,confidence:String)=JSONObject()
  .put("id",id).put("tier",tier).put("title","目标-$id").put("statement","陈述-$id")
  .put("confidence",confidence).put("relation",relation).put("existing_ref","")
  .put("mentions",3).put("first_seen","2026-10-01").put("last_seen","2026-10-05")
  .put("evidence",JSONArray().put(JSONObject().put("source","claude")
   .put("date","2026-10-05").put("quote","引文-$id").put("token","⟨x⟩")))

 private fun proposal(decided:Boolean):JSONObject{
  val body=JSONObject()
   .put("id","weekly-20261006").put("mode","weekly").put("generated_at","2026-10-06T01:49:24+08:00")
   .put("machines",JSONArray().put("Eddie-MBP").put("EddiedeMac-mini"))
   .put("notes","这两条都属单次线索，所以没给 high。").put("gaps",JSONArray())
   .put("suspect",JSONArray().put(JSONObject().put("title","存疑项").put("why","证据太薄")))
   .put("items",JSONArray()
    .put(entry("g1","active","existing","high"))
    .put(entry("g2","active","completed","high"))
    .put(entry("g3","long_term","new","medium")))
  if(decided)body.put("decision",JSONObject().put("request_id","r1").put("approved",JSONArray().put("g1"))
   .put("rejected",JSONArray()).put("applied",JSONObject().put("count",1)
    .put("profile","_global/本体画像/05-目标与规划.md")
    .put("vault",JSONArray().put(JSONObject().put("item","g1")))
    .put("backup","_global/目标提取/backup/20261006-024000")))
  return body
 }

 private fun model(decided:Boolean):WorkbenchModel{
  val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
  lateinit var vm:WorkbenchModel
  ui.runOnUiThread{
   vm=WorkbenchModel(app)
   vm.active=false
   vm.store.token="emulator-ui-fixture"
   vm.goalProposalsFresh=true
   vm.goalProposals=JSONObject().put("items",JSONArray().put(proposal(decided)))
   // 已决策的卡靠 noteId 判定「刚批完，留着给回执」；没有它就不该占首页。
   if(decided)vm.goalProposalNoteId="weekly-20261006"
  }
  return vm
 }

 private fun render(vm:WorkbenchModel){
  ui.setContent{MaterialTheme(colorScheme=Palette){Column(Modifier.verticalScroll(rememberScrollState())){GoalProposalSection(vm)}}}
 }

 /** 一行的合并语义文本：勾选框的 ✓ 也在里面，用它断言勾选状态。 */
 private fun rowText(label:String):String=
  ui.onNodeWithText(label).fetchSemanticsNode().config.getOrNull(SemanticsProperties.Text)
   ?.joinToString("").orEmpty()

 /** 默认只勾高置信、且不是「已完成」的条目。 */
 @Test fun onlyHighConfidenceUnfinishedEntriesArePreselected(){
  val vm=model(decided=false)
  render(vm)
  ui.onNodeWithText("目标-g1").assertIsDisplayed()
  assertTrue("高置信且未完成应默认勾上：${rowText("目标-g1")}",rowText("目标-g1").startsWith("✓"))
  assertFalse("已完成不该默认勾上：${rowText("目标-g2")}",rowText("目标-g2").startsWith("✓"))
  assertFalse("中置信不该默认勾上：${rowText("目标-g3")}",rowText("目标-g3").startsWith("✓"))
  ui.onNodeWithText("批准勾选项 1").assertIsDisplayed().assertIsEnabled()
  ui.onNodeWithText("全部驳回").assertIsDisplayed().assertIsEnabled()
  // 两条 active 各自带分级徽章，一条带「已完成」关系徽章。
  ui.onAllNodesWithText("在推进").assertCountEquals(2)
  ui.onNodeWithText("已完成").assertExists()
 }

 /** 点一下整行就切换勾选，按钮上的计数跟着走。 */
 @Test fun tappingAnEntryTogglesIt(){
  val vm=model(decided=false)
  render(vm)
  ui.onNodeWithText("目标-g3").performClick()
  ui.onNodeWithText("批准勾选项 2").assertIsDisplayed()
  ui.onNodeWithText("目标-g1").performClick()
  ui.onNodeWithText("批准勾选项 1").assertIsDisplayed()
 }

 /** 复核证据：默认收着，展开后逐条列出引文。 */
 @Test fun evidenceStaysCollapsedUntilAsked(){
  val vm=model(decided=false)
  render(vm)
  ui.onNodeWithText("引文-g1").assertDoesNotExist()
  ui.onAllNodesWithText("查看引文")[0].performClick()
  ui.onNodeWithText("· 2026-10-05 [claude] 引文-g1").assertExists()
 }

 /** 口径说明是审计材料，不该盖住要决策的条目。 */
 @Test fun notesStayCollapsedByDefault(){
  val vm=model(decided=false)
  render(vm)
  ui.onNodeWithText("这两条都属单次线索，所以没给 high。").assertDoesNotExist()
  ui.onNodeWithText("口径说明").performClick()
  ui.onNodeWithText("这两条都属单次线索，所以没给 high。").assertExists()
 }

 /** 存疑项只读：不参与勾选，展开才看得到理由。 */
 @Test fun suspectIsReadOnly(){
  val vm=model(decided=false)
  render(vm)
  ui.onNodeWithText("· 存疑项").assertDoesNotExist()
  ui.onNodeWithText("存疑 1 条（未提案）").performScrollTo().performClick()
  ui.onNodeWithText("· 存疑项").assertExists()
  ui.onNodeWithText("证据太薄").assertExists()
 }

 /** 已决策的卡只留回执，操作按钮必须消失，防止二次落库。 */
 @Test fun decidedProposalShowsReceiptWithoutButtons(){
  val vm=model(decided=true)
  render(vm)
  ui.onNodeWithText("🎯 目标提案已提交").assertIsDisplayed()
  ui.onNodeWithText("已批准 1 条，共落库 1 条").performScrollTo().assertIsDisplayed()
  ui.onNodeWithText("批准勾选项 1").assertDoesNotExist()
  ui.onNodeWithText("全部驳回").assertDoesNotExist()
  ui.onNodeWithText("目标-g1").performClick()  // 已决策后点击不应改变任何勾选
  ui.onNodeWithText("批准勾选项 1").assertDoesNotExist()
 }

 /** 回执只属于刚批完那一刻：重进页面后批过的卡不再占首页。 */
 @Test fun decidedCardLeavesHomeOnceTheReceiptIsGone(){
  val vm=model(decided=true)
  ui.runOnUiThread{vm.goalProposalNoteId=""}
  render(vm)
  ui.onNodeWithText("🎯 目标提案已提交").assertDoesNotExist()
  ui.onNodeWithText("目标-g1").assertDoesNotExist()
 }

 /** 同步过的最新记录才允许批准，缓存只读。 */
 @Test fun staleCacheCannotBeApproved(){
  val vm=model(decided=false)
  ui.runOnUiThread{vm.goalProposalsFresh=false}
  render(vm)
  ui.onNodeWithText("全部驳回").assertIsNotEnabled()
  ui.onNodeWithText("离线记录，同步后才能批准。").assertExists()
 }
}
