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

class SupplementExperienceTest {
 @get:Rule val ui=createComposeRule()
 private fun open(state:String){
  lateinit var vm:WorkbenchModel
  ui.runOnUiThread{
   vm=WorkbenchModel(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application)
   vm.active=false;vm.taskLedgerFresh=true
   val task=JSONObject().put("id","task-test").put("title","整理结果").put("input_sources",JSONObject().put("input-test","human-test"))
    .put("inputs",JSONArray().put(JSONObject().put("request_id","input-test").put("state",state)))
   vm.taskLedger=JSONObject().put("items",JSONArray().put(task))
  }
  ui.setContent{MaterialTheme{SupplementCards(vm,JSONObject().put("id","human-test"))}}
 }
 @Test fun queuedShowsChangeToNew(){open("queued");ui.onNodeWithText("改为新事项").assertIsDisplayed()}
 @Test fun deliveredNeverClaimsRevoke(){open("delivered");ui.onNodeWithText("另开新事项").assertIsDisplayed();ui.onNodeWithText("原任务可能已收到这条补充，无法撤回").assertExists()}
 @Test fun unknownNeverClaimsRevoke(){open("unknown");ui.onNodeWithText("另开新事项").assertIsDisplayed();ui.onAllNodesWithText("改为新事项").assertCountEquals(0)}
}
