package work.eddie.sessions

import android.graphics.Bitmap
import android.util.Log
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Uses the real main Activity, real bottom navigation, and the actual Hermes header. */
class HermesHeaderExperienceTest {
 @get:Rule val ui=createAndroidComposeRule<MainActivity>()
 @Test fun companionStaysAboveItsCardAndLegacyPhasesHaveNoTaskAction(){
  lateinit var vm:WorkbenchModel
  ui.runOnUiThread{
   vm=ViewModelProvider(ui.activity)[WorkbenchModel::class.java]
   vm.active=false;vm.hermesVoicePhase="idle";vm.hermesVoiceNote="";vm.hermesSendNote="";vm.hermesError="";vm.error=""
   vm.hermesLoading=false;vm.hermesStreaming=false;vm.hermesDraft="";vm.hermesReference=null
   vm.taskDetailId="";vm.hermesOutbox=emptyList();vm.outgoingMessages.clear()
   vm.taskLedger=JSONObject().put("items",JSONArray());vm.taskLedgerFresh=true
   val tasks=JSONArray().put(JSONObject().put("id","think").put("title","分析用户请求").put("status","done"))
    .put(JSONObject().put("id","reply").put("title","整理阶段回复").put("status","done"))
    .put(JSONObject().put("id","tool-old").put("kind","tool").put("title","核对工具回执").put("status","failed"))
   val events=JSONArray().put(JSONObject().put("id","tool-old").put("kind","tool").put("status","failed").put("text","正在使用 bookkeeping"))
   val message=JSONObject().put("id","header-message").put("role","user").put("text","继续核对执行记录并修复界面")
    .put("status","running").put("phase","executing").put("active_tool","git_pull").put("tasks",tasks).put("work_events",events)
   vm.hermes=JSONObject().put("conversation_id","header-fixture").put("messages",JSONArray().put(message)).put("runs",JSONArray())
   vm.hermesFresh=true
  }
  ui.waitForIdle()
  if(ui.onAllNodesWithText("完成").fetchSemanticsNodes().isNotEmpty())ui.onNodeWithText("完成").performClick()
  ui.waitForIdle()
  ui.onNodeWithTag("hermes-header-avatar",useUnmergedTree=true).assertIsDisplayed()
  ui.onNodeWithTag("avatar-status-pill",useUnmergedTree=true).assertIsDisplayed()
  ui.onAllNodesWithText("Pi",substring=false).assertCountEquals(0)
  ui.onNodeWithText("正在使用 git_pull").assertIsDisplayed()
  val avatar=ui.onNodeWithTag("hermes-header-avatar",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
  val card=ui.onNodeWithTag("avatar-status-pill",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
  val header=ui.onNodeWithTag("hermes-fading-header",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
  assertTrue("Card must start below the complete companion: avatar=$avatar card=$card",card.top>=avatar.bottom-1f)
  assertTrue(card.width>avatar.width)
  assertTrue("Status must remain a single row at the configured font size",card.height<avatar.height*.75f*ui.activity.resources.configuration.fontScale.coerceAtLeast(1f))
  assertTrue("Header must contain enlarged card text",card.bottom<=header.bottom)
  ui.onNodeWithTag("agent-task-think",useUnmergedTree=true).assertDoesNotExist()
  ui.onNodeWithTag("agent-work-toggle-header-message").performClick()
  ui.onNodeWithTag("agent-task-think",useUnmergedTree=true).assertHasNoClickAction()
  ui.onNodeWithTag("agent-task-reply",useUnmergedTree=true).assertHasNoClickAction()
  ui.onNodeWithText("已处理").assertIsDisplayed()
  ui.onNodeWithText("回复已生成").assertIsDisplayed()
  ui.onNodeWithText("工具调用失败 · bookkeeping").assertIsDisplayed()
  ui.onNodeWithContentDescription("调用失败").assertIsDisplayed()
  ui.onNodeWithTag("agent-task-think",useUnmergedTree=true).performTouchInput{click()}
  ui.runOnIdle{assertEquals("",vm.taskDetailId);assertEquals(0,vm.externalTaskRoute)}
  val screenCase=InstrumentationRegistry.getArguments().getString("screenCase","default")
  val bitmap=ui.onNodeWithTag("workbench-inset-root").captureToImage().asAndroidBitmap()
  File(ui.activity.getExternalFilesDir(null),"com-main-header-$screenCase.png").outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
  val headerBitmap=ui.onNodeWithTag("hermes-fading-header",useUnmergedTree=true).captureToImage().asAndroidBitmap()
  File(ui.activity.getExternalFilesDir(null),"com-avatar-header-$screenCase.png").outputStream().use{headerBitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
  Log.i("ComHeaderGeometry","case=$screenCase avatar=$avatar card=$card header=$header fontScale=${ui.activity.resources.configuration.fontScale}")
  ui.runOnUiThread{
   vm.hermes=JSONObject(vm.hermes.toString()).apply{
    getJSONArray("messages").getJSONObject(0).put("status","completed").put("phase","completed").put("active_tool",JSONObject.NULL)
   }
  }
  ui.waitForIdle()
  ui.onNodeWithTag("hermes-header-avatar",useUnmergedTree=true).assertIsDisplayed()
  ui.onNodeWithTag("avatar-status-pill",useUnmergedTree=true).assertDoesNotExist()
  ui.onAllNodesWithText("空闲",substring=false).assertCountEquals(0)
  val idleHeader=ui.onNodeWithTag("hermes-fading-header",useUnmergedTree=true).captureToImage().asAndroidBitmap()
  File(ui.activity.getExternalFilesDir(null),"com-avatar-header-idle-$screenCase.png").outputStream().use{idleHeader.compress(Bitmap.CompressFormat.PNG,100,it)}
 }
}
