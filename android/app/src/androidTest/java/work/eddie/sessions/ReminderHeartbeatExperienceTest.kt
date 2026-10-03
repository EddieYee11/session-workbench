package work.eddie.sessions
import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Rule
import org.junit.Test
class ReminderHeartbeatExperienceTest {
 @get:Rule val ui=createComposeRule()
 private fun model():WorkbenchModel{
  lateinit var vm:WorkbenchModel
  ui.runOnUiThread{vm=WorkbenchModel(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application);vm.active=false;vm.store.token=""}
  return vm
 }
 @Test fun pendingRecordShowsFourActionsAndFailure(){
  val vm=model();ui.runOnUiThread{vm.reminderFresh=true;vm.reminderNote="提醒动作未确认：提醒已变化，请刷新后再操作；不会自动重放"}
  ui.setContent{MaterialTheme{ReminderCard(vm,JSONObject().put("id","real-fixture").put("text","测试提醒").put("due","2099-01-01 12:00").put("status","pending"))}}
  for(t in listOf("确认","+10 分钟","+1 小时","取消"))ui.onNodeWithText(t).assertIsDisplayed()
  ui.onNodeWithText(vm.reminderNote).assertExists()
 }
 @Test fun unavailableSourceDisablesActions(){
  val vm=model()
  ui.setContent{MaterialTheme{ReminderCard(vm,JSONObject().put("id","fixture").put("text","提醒").put("status","pending"))}}
  for(t in listOf("确认","+10 分钟","+1 小时","取消"))ui.onNodeWithText(t).assertIsNotEnabled()
 }
 @Test fun heartbeatRemainsShadowUntilVerified(){
  val vm=model();ui.runOnUiThread{vm.heartbeatState=JSONObject().put("settings",JSONObject().put("paused",false).put("shadow",true)).put("shadow_verified",false).put("items",JSONArray())}
  ui.setContent{MaterialTheme{HeartbeatSettings(vm)}}
  ui.onNodeWithText("完成两次有效影子观察后可手动启用").assertExists()
  ui.onNodeWithText("心跳诊断").performClick();ui.onNodeWithText("还没有观察记录").assertExists()
 }
}
