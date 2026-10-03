package work.eddie.sessions
import android.app.Application
import android.graphics.Bitmap
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Rule
import org.junit.Test
import java.io.File
class ComVisualStatesTest {
 @get:Rule val ui=createComposeRule()
 private var model:WorkbenchModel?=null
 private var oldBase="";private var oldToken=""
 private fun fixture():WorkbenchModel{
  lateinit var vm:WorkbenchModel
  ui.runOnUiThread{
   vm=WorkbenchModel(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application);vm.active=false
   oldBase=vm.store.base;oldToken=vm.store.token;vm.store.base="https://127.0.0.1:9";vm.store.token=""
   vm.hermes=JSONObject();vm.taskLedger=JSONObject().put("items",JSONArray());vm.taskLedgerFresh=true;vm.taskFilter="all";vm.taskDetailId=""
  };model=vm;return vm
 }
 @After fun restore(){model?.let{vm->ui.runOnUiThread{vm.store.prefs.edit().putString("base",oldBase).apply();vm.store.token=oldToken;vm.active=false}}}
 private fun capture(name:String){
  ui.waitForIdle();val bitmap=ui.onNodeWithTag("visual-root").captureToImage().asAndroidBitmap()
  File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null),"com-visual-$name.png").outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
 }
 @Test fun emptyAndLongTitleUnknownHaveRealRenderedEvidence(){
  val vm=fixture();ui.setContent{MaterialTheme(colorScheme=Palette){Surface(Modifier.fillMaxSize().testTag("visual-root"),color=Paper){TaskActivityPage(vm){}}}}
  ui.onNodeWithText("还没有后台任务").assertIsDisplayed();capture("empty")
  ui.runOnUiThread{vm.taskLedger=JSONObject().put("items",JSONArray().put(JSONObject().put("id","long-title").put("title","这是一项需要核实原始执行回执与全部交付证据的非常长的项目任务标题，请不要根据未确认结果重复执行").put("agent","pi").put("status","unknown")))}
  ui.onNodeWithTag("task-ledger-long-title").assertIsDisplayed();capture("long-title-unknown")
 }
 @Test fun actualNetworkFailureIsShownWithoutSuccess(){
  val vm=fixture();val item=JSONObject().put("id","rmVisual${System.nanoTime()}").put("text","断开来源时不假装成功").put("due","2099-01-01 12:00").put("status","pending")
  ui.runOnUiThread{vm.reminderFresh=true}
  ui.setContent{MaterialTheme(colorScheme=Palette){Surface(Modifier.fillMaxSize().testTag("visual-root"),color=Paper){ReminderCard(vm,item)}}}
  ui.onNodeWithText("+10 分钟").performClick()
  ui.waitUntil(15000){vm.reminderNote.startsWith("提醒动作未确认")}
  ui.onNodeWithText(vm.reminderNote).assertIsDisplayed();ui.onNodeWithText("+10 分钟").assertIsNotEnabled();capture("actual-error")
  vm.store.secureCache("reminder-action-${item.optString("id")}.enc",JSONObject())
 }
}
