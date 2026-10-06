package work.eddie.sessions

import android.app.Application
import android.view.WindowInsets
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ConversationImeGestureTest {
 @get:Rule val ui=createAndroidComposeRule<androidx.activity.ComponentActivity>()
 private fun imeVisible():Boolean=ui.activity.window.decorView.rootWindowInsets?.isVisible(WindowInsets.Type.ime())==true
 @Test fun historyDismissesImeAndOnlyFurtherLatestPullShowsIt(){
  lateinit var vm:WorkbenchModel
  ui.runOnUiThread{
   ui.activity.window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
   vm=WorkbenchModel(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application)
   vm.active=false;vm.hermesFresh=true;vm.hermesLoading=false;vm.hermesVoicePhase="idle"
   val rows=JSONArray()
   repeat(40){i->rows.put(JSONObject().put("id","gesture-$i").put("role","assistant").put("status","completed")
    .put("text","第 $i 条历史消息，这是足够长的阅读内容，用来验证回看历史时键盘收起。"))}
   vm.hermes=JSONObject().put("conversation_id","gesture-fixture").put("messages",rows).put("runs",JSONArray())
  }
  ui.setContent{MaterialTheme(colorScheme=Palette){HermesChat(vm,{},{},{})}}
  ui.waitForIdle()
  ui.onNodeWithTag("hermes-composer").performClick()
  ui.waitUntil(10000){imeVisible()}
  ui.onNodeWithTag("hermes-message-list").performTouchInput{swipeDown()}
  ui.waitUntil(10000){!imeVisible()}
  ui.onNodeWithTag("hermes-header-avatar",true).assertIsNotDisplayed()
  ui.onNodeWithTag("hermes-message-list").performTouchInput{swipeDown()}
  ui.waitForIdle();assertFalse(imeVisible())
  ui.onNodeWithTag("hermes-jump-latest").performClick()
  ui.waitForIdle();assertFalse(imeVisible())
  ui.onNodeWithTag("hermes-message-list").performTouchInput{swipeUp()}
  ui.waitUntil(10000){imeVisible()}
 }
}
