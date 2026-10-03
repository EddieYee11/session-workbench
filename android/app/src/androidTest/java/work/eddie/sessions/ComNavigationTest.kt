package work.eddie.sessions

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Runs at both phone and unfolded widths; all sample data stays on the emulator. */
class ComNavigationTest {
 @get:Rule val ui=createComposeRule()

 private fun open():WorkbenchModel{
  val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
  lateinit var vm:WorkbenchModel
  ui.runOnUiThread{
   vm=WorkbenchModel(app)
   vm.active=false
   // Tests share app data; a leftover persisted draft would change what the composer contains.
   vm.updateHermesDraft("")
   vm.hermesOutbox=emptyList();vm.outgoingMessages.clear();vm.hermesSendNote="";vm.hermesError=""
   vm.hermes=JSONObject().put("conversation_id","ui-acceptance").put("messages",JSONArray()
    .put(JSONObject().put("id","sample-user").put("role","user").put("text","今天想把 Com! 整理得更轻盈一点。").put("status","completed"))
    .put(JSONObject().put("id","sample-agent").put("role","assistant").put("text","好，我们一起慢慢整理。\n\n今天、工作和活动都在下方，随时可以切换。").put("status","completed")))
  }
  ui.setContent{MaterialTheme(colorScheme=Palette){Workbench(vm,"",0){}}}
  // A clean emulator opens the pairing sheet; dismiss it without changing credentials.
  ui.waitForIdle()
  if(ui.onAllNodesWithText("Com! · 设置").fetchSemanticsNodes().isNotEmpty()){
   InstrumentationRegistry.getInstrumentation().uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
   ui.waitUntil(5000){ui.onAllNodesWithText("Com! · 设置").fetchSemanticsNodes().isEmpty()}
  }
  ui.waitForIdle()
  return vm
 }

 private fun capture(name:String){
  val context=InstrumentationRegistry.getInstrumentation().targetContext
  val width=context.resources.configuration.screenWidthDp
  val file=File(context.getExternalFilesDir(null),"com-ui-${width}dp-$name.png")
  ui.waitForIdle()
  ui.mainClock.advanceTimeBy(500)
  InstrumentationRegistry.getInstrumentation().waitForIdleSync()
  android.os.SystemClock.sleep(350)
  val screenshot=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
  file.outputStream().use{screenshot.compress(Bitmap.CompressFormat.PNG,100,it)}
 }

 @Test fun destinationsStayBelowConversation(){
  open()
  ui.onNodeWithText("记一笔").assertDoesNotExist()
  ui.onNodeWithText("今日日程").assertDoesNotExist()
  val message=ui.onNodeWithText("今天想把 Com! 整理得更轻盈一点。").fetchSemanticsNode().boundsInRoot
  val tabs=listOf("对话","今天","工作").map{
   ui.onNodeWithContentDescription(it).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
  }
  check(tabs.all{it.top>message.bottom}){"Navigation must sit below conversation at every width"}
  check(tabs.zipWithNext().all{(left,right)->left.left<right.left&&kotlin.math.abs(left.top-right.top)<2f})
  capture("conversation")
 }

 @Test fun moreOpensBottomSheetAndRoutesToLedger(){
  open()
  ui.onNodeWithContentDescription("更多").performClick()
  capture("more")
  ui.onNodeWithText("账本").assertIsDisplayed().performClick()
  ui.onNodeWithText("本月账本").assertIsDisplayed()
  ui.onNodeWithContentDescription("对话").performClick()
  ui.onNodeWithText("今天想把 Com! 整理得更轻盈一点。").assertIsDisplayed()
 }

 @Test fun workHistoryOpensAndClosesWithoutLosingBottomNavigation(){
  open()
  ui.onNodeWithContentDescription("工作").performClick()
  capture("work")
  ui.onNodeWithContentDescription("工作会话历史").performClick()
  ui.onNodeWithText("所有会话").assertIsDisplayed()
  ui.onNodeWithText("新聊天").performClick()
  ui.onNodeWithContentDescription("更多").assertIsDisplayed()
 }

 @Test fun keyboardKeepsComposerVisibleAndReturnsNavigationAfterDismissal(){
  open()
  ui.onNode(hasSetTextAction()).performClick().performTextInput("测试草稿")
  ui.waitUntil(5_000){ui.onAllNodesWithContentDescription("工作").fetchSemanticsNodes().isEmpty()}
  ui.onNodeWithText("测试草稿").assertIsDisplayed()
  capture("keyboard")
  ui.onNode(hasSetTextAction()).performTextClearance()
  InstrumentationRegistry.getInstrumentation().uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
  ui.waitUntil(5_000){ui.onAllNodesWithContentDescription("工作").fetchSemanticsNodes().isNotEmpty()}
 }

 @Test fun todayReadsPhoneCalendarWithoutPairing(){
  open()
  ui.onNodeWithContentDescription("今天").performClick()
  ui.waitUntil(5000){ui.onAllNodesWithText("打开日历").fetchSemanticsNodes().isNotEmpty()}
  ui.onNodeWithText("打开日历").assertIsDisplayed()
  capture("today")
  ui.onNodeWithText("打开日历").performClick()
  ui.onNodeWithText("手机日历 · 本地读取").assertIsDisplayed()
  ui.onNodeWithContentDescription("返回").performClick()
  ui.onNodeWithText("待我处理").assertIsDisplayed()
 }

 @Test fun backgroundTasksKeepIdentityAndCacheState(){
  val vm=open()
  ui.runOnUiThread{
   vm.taskLedger=JSONObject().put("items",JSONArray()
    .put(JSONObject().put("id","task-A").put("title","检查会话列表").put("status","running").put("agent","codex").put("message_id","same-parent"))
    .put(JSONObject().put("id","task-B").put("title","排查下载问题").put("status","queued").put("agent","codex").put("message_id","same-parent")))
   vm.taskLedgerFresh=false
  }
  ui.onNodeWithContentDescription("今天").performClick()
  ui.onNodeWithTag("today-ongoing").performScrollTo().performClick()
  ui.onNodeWithText("检查会话列表").assertIsDisplayed()
  ui.onNodeWithText("排查下载问题").assertIsDisplayed()
  ui.onNodeWithText("检查会话列表").performClick()
  ui.onNodeWithText("离线缓存，同步后才能操作").assertIsDisplayed()
  ui.onNodeWithText("发送补充要求").assertIsNotEnabled()
  ui.onNodeWithText("请求停止").assertIsNotEnabled()
  capture("tasks")
 }
}
