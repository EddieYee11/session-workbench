package work.eddie.sessions

import android.app.Application
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** The originating message remains reachable after leaving and recreating the chat screen. */
class WorkCardNavigationTest {
 @get:Rule val ui=createComposeRule()
 @Test fun taskCardOpensExactTaskAndReturnsToItsOriginalMessage(){
  lateinit var vm:WorkbenchModel
  InstrumentationRegistry.getInstrumentation().runOnMainSync{
   vm=WorkbenchModel(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application)
   vm.active=false;vm.hermesVisible=false;vm.hermesFresh=true;vm.taskLedgerFresh=true
   vm.hermesOutbox=emptyList();vm.outgoingMessages.clear()
   val parent=JSONObject().put("id","origin-message").put("role","user").put("text","请升级 Com 的任务关联").put("status","delegated")
    .put("tasks",JSONArray().put(JSONObject().put("id","task-exact").put("kind","task").put("title","任务关联升级").put("status","running")))
   val messages=JSONArray().put(parent)
   repeat(12){i->messages.put(JSONObject().put("id","later-$i").put("role",if(i%2==0)"user" else "assistant").put("text","后续对话 $i").put("status","completed"))}
   vm.hermes=JSONObject().put("conversation_id","local-card-navigation").put("messages",messages).put("runs",JSONArray())
   vm.taskLedger=JSONObject().put("items",JSONArray().put(JSONObject().put("id","task-exact").put("title","任务关联升级").put("status","running").put("message_id","origin-message").put("agent","codex")))
  }
  ui.setContent{
   var page by remember{mutableStateOf("hermes")}
   LaunchedEffect(vm.externalTaskRoute){if(vm.externalTaskRoute>0)page="task"}
   LaunchedEffect(vm.externalHermesRoute){if(vm.externalHermesRoute>0)page="hermes"}
   MaterialTheme(colorScheme=Palette){Box(Modifier.width(360.dp).height(700.dp).testTag("navigation-fixture")){
    if(page=="task")TaskActivityPage(vm){vm.returnToHermes()}
    else HermesChat(vm,{},false,{page="task"})
   }}
  }
  ui.onNodeWithTag("hermes-message-list").performScrollToNode(hasTestTag("agent-task-task-exact"))
  ui.onNodeWithTag("agent-task-task-exact").performClick()
  ui.onNodeWithTag("task-ledger-task-exact").assertIsDisplayed()
  ui.runOnIdle{assertEquals("task-exact",vm.taskDetailId);assertEquals("origin-message",vm.taskReturnMessageId)}
  ui.onNodeWithText("回到交办消息").performClick()
  ui.onNodeWithText("请升级 Com 的任务关联").assertIsDisplayed()
  ui.onNodeWithTag("agent-task-task-exact").assertIsDisplayed()
  ui.runOnIdle{assertEquals("",vm.hermesTargetMessageId);assertEquals("",vm.taskDetailId)}
 }
}
