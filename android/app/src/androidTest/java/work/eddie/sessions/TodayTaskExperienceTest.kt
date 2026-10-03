package work.eddie.sessions

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.graphics.asAndroidBitmap
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

/** Real Workbench routes with local records; never send or approve a live task. */
class TodayTaskExperienceTest {
 @get:Rule val ui=createComposeRule()
 private var vm:WorkbenchModel?=null
 private var savedBase=""
 private var savedToken=""
 private fun fixture():WorkbenchModel{
  lateinit var model:WorkbenchModel
  ui.runOnUiThread{
   val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
   val fixtureStore=Store(app)
   savedBase=fixtureStore.base;savedToken=fixtureStore.token
   fixtureStore.base="https://127.0.0.1:9";fixtureStore.token=""
   model=WorkbenchModel(app);model.active=false
   model.rootPage="sources";model.hermesOutbox=emptyList();model.outgoingMessages.clear();model.hermesDraft=""
   model.hermesReference=null;model.hermesSendNote="";model.hermesError="";model.error="";model.hermesVoicePhase="idle"
   model.taskDetailId="";model.taskFilter="all";model.hermesFresh=true;model.taskLedgerFresh=true;model.workProposalsFresh=true;model.signalsFresh=true
   val messages=JSONArray().put(JSONObject().put("id","source-A").put("role","user").put("text","请核对原交办 A").put("status","completed"))
    .put(JSONObject().put("id","source-B").put("role","user").put("text","请处理执行任务 B").put("status","completed"))
   model.hermes=JSONObject().put("conversation_id","local-today-fixture").put("messages",messages).put("runs",JSONArray())
   val tasks=JSONArray()
   listOf("decision-A" to "unknown","active-B" to "running","verify-C" to "execution_finished","done-D" to "execution_finished").forEach{(id,status)->
    val title=mapOf("decision-A" to "核对账本任务回执","active-B" to "更新 Com 任务关联","verify-C" to "整理执行结果","done-D" to "已验收的消息索引").getValue(id)
    tasks.put(JSONObject().put("id",id).put("title",title).put("status",status).put("agent","codex")
     .put("message_id",if(id=="decision-A")"source-A"else"source-B").put("acceptance_passed",id=="done-D"))
   }
   model.taskLedger=JSONObject().put("items",tasks)
   model.workProposals=JSONObject().put("items",JSONArray())
   model.signals=JSONObject().put("items",JSONArray())
   model.personal=JSONObject().put("generated_at",System.currentTimeMillis()/1000.0).put("finance",JSONObject().put("available",false))
   model.personalFresh=true
   vm=model
  }
  ui.setContent{MaterialTheme(colorScheme=Palette){Workbench(model,"",0,{})}}
  ui.onNodeWithText("完成").performClick()
  return model
 }
 @After fun restoreFixtureConfiguration(){vm?.let{model->ui.runOnUiThread{model.store.prefs.edit().putString("base",savedBase).apply();model.store.token=savedToken;model.active=false}}}
 private fun screenshot(name:String){
  val screen=InstrumentationRegistry.getArguments().getString("screenCase","default")
  val bitmap=ui.onNodeWithTag("workbench-inset-root").captureToImage().asAndroidBitmap()
  File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null),"com-$name-$screen.png").outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
 }
 @Test fun todayOpensExactTaskAndReturnsToTodayThenOriginalMessage(){
  val model=fixture()
  ui.onNodeWithText("待我处理").assertIsDisplayed()
  ui.onNodeWithTag("today-item-decision-A").assertIsDisplayed()
  screenshot("today")
  ui.onNodeWithTag("today-item-decision-A").performClick()
  ui.onNodeWithText("任务详情").assertIsDisplayed()
  ui.runOnIdle{assertEquals("decision-A",model.taskDetailId);assertEquals("source-A",model.taskReturnMessageId)}
  ui.onNodeWithContentDescription("返回上一页").performClick()
  ui.onNodeWithText("待我处理").assertIsDisplayed()
  ui.onNodeWithTag("today-item-decision-A").performClick()
  ui.onNodeWithText("回到交办消息").performClick()
  ui.onNodeWithText("请核对原交办 A").assertIsDisplayed()
  ui.runOnIdle{assertEquals("hermes",model.rootPage);assertEquals("",model.hermesTargetMessageId)}
 }
 @Test fun ongoingSummaryOpensActiveFilterAndReviewDoesNotClaimDone(){
  val model=fixture()
  ui.onNodeWithTag("today-ongoing").performScrollTo().performClick()
  ui.runOnIdle{assertEquals("active",model.taskFilter)}
  ui.onNodeWithTag("task-ledger-active-B").assertIsDisplayed()
  ui.onNodeWithTag("task-ledger-done-D").assertDoesNotExist()
  screenshot("tasks-active")
  ui.onNodeWithTag("task-filter-verify").performScrollTo().performClick()
  ui.onNodeWithTag("task-ledger-verify-C").assertIsDisplayed()
  ui.onNodeWithTag("task-ledger-done-D").assertDoesNotExist()
  ui.onNodeWithTag("task-filter-done").performScrollTo().performClick()
  ui.onNodeWithTag("task-ledger-done-D").assertIsDisplayed()
  ui.onNodeWithTag("task-ledger-verify-C").assertDoesNotExist()
  for(tab in listOf("hermes","sources","activity","work","settings"))ui.onNodeWithTag("nav-$tab").assertIsDisplayed()
 }
 @Test fun pendingProposalAppearsOnceAndNotificationReviewHasSeparateRoute(){
  val model=fixture()
  ui.runOnUiThread{
   val proposal=JSONObject().put("id","decision-A").put("title","重复授权建议").put("status","proposed").put("agent","codex").put("parent_message_id","source-A").put("expires_at",System.currentTimeMillis()/1000.0+3600)
   model.workProposals=JSONObject().put("items",JSONArray().put(proposal))
   val messages=model.hermes.array("messages")
   assertEquals(1,ledgerTaskRecords(model,messages).count{it.optString("id")=="decision-A"})
   model.signals=JSONObject().put("items",JSONArray().put(JSONObject().put("id","signal-X").put("status","reviewed").put("priority","important").put("summary","本地通知巡检结果")))
  }
  ui.onNodeWithTag("today-item-signals").performScrollTo().performClick()
  ui.onNodeWithText("通知巡检",substring=false).assertIsDisplayed()
  ui.onNodeWithContentDescription("返回今天").performClick()
  ui.onNodeWithText("待我处理").assertIsDisplayed()
  ui.onNodeWithTag("nav-activity").performClick()
  ui.onAllNodesWithTag("task-ledger-decision-A").assertCountEquals(1)
  ui.onNodeWithText("手机通知巡检").assertDoesNotExist()
 }
}
