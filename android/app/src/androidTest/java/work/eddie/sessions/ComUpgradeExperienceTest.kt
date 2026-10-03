package work.eddie.sessions

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

class ComUpgradeExperienceTest{
 @get:Rule val ui=createComposeRule()
 private var vm:WorkbenchModel?=null
 private var savedBase=""
 private var savedToken=""
 private fun model():WorkbenchModel{
  lateinit var m:WorkbenchModel
  ui.runOnUiThread{
   val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
   val store=Store(app);savedBase=store.base;savedToken=store.token;store.token=""
   m=WorkbenchModel(app);m.active=false;m.hermes=JSONObject();m.taskLedger=JSONObject();m.workProposals=JSONObject()
   m.hermesFresh=false;m.taskLedgerFresh=false;m.workProposalsFresh=false;m.hermesLoading=false
   m.hermesError="";m.taskLedgerError="";m.workProposalsError="";m.hermesOutbox=emptyList();m.outgoingMessages.clear()
   m.hermesDraft="";m.hermesSendNote="";m.hermesReference=null;m.hermesVoicePhase="idle";m.personalError=""
   vm=m
  }
  return m
 }
 @After fun restore(){vm?.let{m->ui.runOnUiThread{m.store.prefs.edit().putString("base",savedBase).apply();m.store.token=savedToken;m.active=false}}}
 private fun screenshot(name:String){
  ui.waitForIdle();ui.mainClock.advanceTimeBy(500)
  InstrumentationRegistry.getInstrumentation().waitForIdleSync();android.os.SystemClock.sleep(350)
  val context=InstrumentationRegistry.getInstrumentation().targetContext
  val bitmap=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
  File(context.getExternalFilesDir(null),"com19-$name-${context.resources.configuration.screenWidthDp}dp.png").outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
 }
 @Test fun firstOfflineNeverClaimsConfirmedZeroAndPartialCacheIsExplicit(){
  val m=model()
  ui.setContent{MaterialTheme(colorScheme=Palette){Column{TodayDecisionCard(m,{_,_->},{ });TodayWorkLine(m,{},{})}}}
  ui.onNodeWithText("当前没有待处理项").assertDoesNotExist()
  ui.onNodeWithText("连接后核对待处理事项").assertIsDisplayed()
  ui.onNodeWithText("尚未读取在执行").assertIsDisplayed()
  ui.runOnUiThread{m.hermes=JSONObject().put("messages",JSONArray()).put("synced_at",1700000000.0);m.hermesError="离线"}
  ui.onNodeWithText("上次记录 0 件在执行").assertIsDisplayed()
  ui.onNodeWithText("上次记录没有待处理项，当前待核对").assertIsDisplayed()
  screenshot("cached")
 }
 @Test fun irrelevantNotificationSourceDoesNotInvalidateTaskCounts(){
  val m=model()
  ui.runOnUiThread{
   m.hermesFresh=true;m.taskLedgerFresh=true;m.workProposalsFresh=true;m.signalsFresh=false
  }
  ui.setContent{MaterialTheme(colorScheme=Palette){Column{TodayDecisionCard(m,{_,_->},{ });TodayWorkLine(m,{},{})}}}
  ui.onNodeWithText("当前没有待处理项").assertIsDisplayed()
  ui.onNodeWithText("0 件在执行").assertIsDisplayed()
 }
 @Test fun historyReadingHidesEntireHeaderAndTokensDoNotTakeReadingPosition(){
  val m=model()
  ui.runOnUiThread{
   val messages=JSONArray()
   repeat(24){i->messages.put(JSONObject().put("id","reading-$i").put("role","assistant").put("text","历史正文 $i\n"+"这是一段用于检查完整阅读的长文字。".repeat(10)).put("status","completed").put("created_at",i+1))}
   m.hermes=JSONObject().put("conversation_id","fixture").put("messages",messages).put("runs",JSONArray());m.hermesFresh=true
  }
  ui.setContent{MaterialTheme(colorScheme=Palette){HermesChat(m,{},{},{})}}
  ui.onNodeWithTag("hermes-message-list").performScrollToIndex(8)
  ui.onNodeWithTag("hermes-message-list").performTouchInput{swipeUp(startY=centerY,endY=centerY-200f)}
  ui.onNodeWithTag("hermes-header-avatar",true).assertIsNotDisplayed()
  ui.onNodeWithContentDescription("回到最新").assertIsDisplayed()
  ui.onNodeWithText("回复结束",substring=true).assertDoesNotExist()
  screenshot("reading")
  val anchor=ui.onNodeWithTag("conversation-message-reading-8").fetchSemanticsNode().boundsInRoot
  ui.runOnUiThread{m.hermes=JSONObject(m.hermes.toString()).apply{getJSONArray("messages").getJSONObject(23).put("text","最新 token 已到达")}}
  ui.onNodeWithTag("hermes-header-avatar",true).assertIsNotDisplayed()
  val after=ui.onNodeWithTag("conversation-message-reading-8").fetchSemanticsNode().boundsInRoot
  assertEquals(anchor.top,after.top,1f)
  ui.runOnUiThread{
   val older=JSONArray().put(JSONObject().put("id","older-row").put("role","assistant").put("text","分页得到的旧消息").put("status","completed"))
   m.hermes.array("messages").forEach{older.put(it)}
   m.hermes=JSONObject(m.hermes.toString()).put("messages",older)
  }
  val prepended=ui.onNodeWithTag("conversation-message-reading-8").fetchSemanticsNode().boundsInRoot
  assertEquals("Keyset prepend must preserve the reading anchor",after.top,prepended.top,1f)
  ui.onNodeWithContentDescription("回到最新").performClick()
  ui.onNodeWithTag("hermes-header-avatar",true).assertIsDisplayed()
 }
 @Test fun workHasOneHeadingAndAllNavigationLabelsAreVisible(){
  val m=model()
  ui.runOnUiThread{
   m.rootPage="work";m.selected="";m.allRows=listOf(JSONObject().put("id","local-work").put("agent","claude").put("display_title","继续上次工作").put("cwd","/fixture/项目甲").put("status","completed").put("updated",1700000000))
  }
  ui.setContent{MaterialTheme(colorScheme=Palette){Workbench(m,"",0,{})}}
  ui.waitForIdle()
  if(ui.onAllNodesWithText("Com! · 设置").fetchSemanticsNodes().isNotEmpty()){
   InstrumentationRegistry.getInstrumentation().uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
   ui.waitUntil(5000){ui.onAllNodesWithText("Com! · 设置").fetchSemanticsNodes().isEmpty()}
  }
  ui.onNodeWithText("继续上次工作").assertIsDisplayed()
  ui.onNodeWithText("项目甲").assertIsDisplayed()
  for(label in listOf("对话","今天","工作"))ui.onAllNodesWithText(label).onLast().assertIsDisplayed()
  ui.onNodeWithText("Com!").assertDoesNotExist()
  ui.onNodeWithTag("work-fixed-header").assertDoesNotExist()
  screenshot("work")
 }
 @Test fun incomingSharePreservesExistingDraftAndNeverSendsAutomatically(){
  val m=model()
  ui.runOnUiThread{m.hermesDraft="已有草稿";m.receiveShare("https://example.com/资料","浏览器")}
  ui.setContent{MaterialTheme(colorScheme=Palette){IncomingShareSheet(m)}}
  ui.onNodeWithText("交给 Com!").assertIsDisplayed()
  ui.onNodeWithText("放入主对话草稿").performClick()
  ui.runOnIdle{
   assertEquals("已有草稿\n\nhttps://example.com/资料",m.hermesDraft)
   assertTrue(m.hermesOutbox.isEmpty())
   assertTrue(m.incomingShare.length()==0)
  }
 }

 @Test fun taskDetailAdaptsToWindowAndKeepsSelectedTask(){
  val m=model()
  ui.runOnUiThread{
   m.rootPage="activity";m.taskDetailId="adaptive-task";m.taskLedgerFresh=true
   m.taskLedger=JSONObject().put("items",JSONArray().put(JSONObject().put("id","adaptive-task").put("title","可继续的测试任务").put("status","execution_finished").put("agent","codex").put("result","已生成真实结果")))
  }
  ui.setContent{MaterialTheme(colorScheme=Palette){Workbench(m,"",0,{})}}
  ui.waitForIdle()
  if(ui.onAllNodesWithText("Com! · 设置").fetchSemanticsNodes().isNotEmpty()){
   InstrumentationRegistry.getInstrumentation().uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
   ui.waitUntil(5000){ui.onAllNodesWithText("Com! · 设置").fetchSemanticsNodes().isEmpty()}
  }
  val config=InstrumentationRegistry.getInstrumentation().targetContext.resources.configuration
  if(config.screenWidthDp>=660*config.fontScale.coerceAtLeast(1f)){
   ui.onNodeWithTag("task-list-detail").assertIsDisplayed()
   ui.onNodeWithTag("task-detail-adaptive-task").assertIsDisplayed()
  }else ui.onNodeWithTag("task-list-detail").assertDoesNotExist()
  ui.runOnIdle{assertEquals("adaptive-task",m.taskDetailId)}
  screenshot("adaptive-task")
 }

}
