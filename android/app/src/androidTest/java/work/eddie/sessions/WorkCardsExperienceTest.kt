package work.eddie.sessions

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
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
import java.io.File

/** Local fixtures verify real Compose layout and persist screenshots for visual review. */
class WorkCardsExperienceTest {
 @get:Rule val ui=createComposeRule()
 private fun capture(name:String){
  val bitmap=ui.onNodeWithTag("work-card-preview").captureToImage().asAndroidBitmap()
  val context=InstrumentationRegistry.getInstrumentation().targetContext
  File(context.getExternalFilesDir(null),"com-work-card-$name.png").outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
 }
 @Test fun runningCardOpensTheExactTaskAndUsesRecordedEvents(){
  val message=JSONObject().put("id","message-running").put("role","user").put("status","delegated")
   .put("tasks",JSONArray().put(JSONObject().put("id","tool-read").put("title","读取现有源码").put("kind","tool").put("status","done"))
    .put(JSONObject().put("id","task-upgrade").put("title","整合工作卡并验收").put("kind","task").put("status","running")))
   .put("work_events",JSONArray().put(JSONObject().put("id","event-1").put("kind","tool.completed").put("text","源码已读取，正在核对消息关联").put("at",1.0)))
  var opened=""
  ui.setContent{MaterialTheme(colorScheme=Palette){Column(Modifier.width(360.dp).height(450.dp).background(Paper).padding(12.dp).testTag("work-card-preview")){
   AvatarStatusPill("正在执行")
   AgentWorkCard(message,true){opened=it}
  }}}
  ui.onNodeWithText("工具已执行").assertDoesNotExist()
  ui.onNodeWithText("源码已读取，正在核对消息关联").assertDoesNotExist()
  ui.onNodeWithTag("agent-work-toggle-message-running").performClick()
  ui.onNodeWithText("工具已执行").assertIsDisplayed()
  ui.onNodeWithText("源码已读取，正在核对消息关联").assertIsDisplayed()
  ui.onNodeWithTag("agent-task-task-upgrade").performClick()
  ui.runOnIdle{assertEquals("task-upgrade",opened)}
  capture("running")
 }
 @Test fun searchingDoesNotAutomaticallyExposeToolDetails(){
  val tool=JSONObject().put("id","search-tool").put("role","tool").put("title","Bash 执行记录").put("text","只有点开才能查看的日志")
  ui.setContent{MaterialTheme(colorScheme=Palette){Column(Modifier.width(360.dp).height(450.dp).testTag("work-card-preview")){
   ProcessGroup(listOf(tool),"日志",16f,false)
  }}}
  ui.onNodeWithText("只有点开才能查看的日志").assertDoesNotExist()
  ui.onNodeWithText("含匹配").assertIsDisplayed()
  ui.onNodeWithContentDescription("展开处理过程").performClick()
  ui.onNodeWithText("Bash 执行记录").assertIsDisplayed()
  ui.onNodeWithText("只有点开才能查看的日志").assertDoesNotExist()
  ui.onNodeWithContentDescription("展开执行记录").performClick()
  ui.onNodeWithText("只有点开才能查看的日志").assertIsDisplayed()
 }
 @Test fun finishedAndVerifiedSummariesRenderDifferentEvidenceStates(){
  var verified by mutableStateOf(false)
  ui.setContent{MaterialTheme(colorScheme=Palette){Column(Modifier.width(360.dp).height(520.dp).background(Paper).padding(12.dp).testTag("work-card-preview")){
   val summary=JSONObject().put("task_id","task-upgrade").put("title","整合工作卡")
    .put("status",if(verified)"done" else "execution_finished").put("verification_status",if(verified)"passed" else "pending")
    .put("duration_ms",12000).put("finished_at","10-03 15:20")
    .put("steps",JSONArray().put(JSONObject().put("id","task-upgrade").put("title","整合并构建").put("status","execution_finished").put("detail","构建已完成，真实使用路径待验收")))
    .put("outcomes",JSONArray().put("工作卡能显示真实记录"))
   TaskSummaryCard(JSONObject().put("id","message-finished").put("summary",summary))
  }}}
  ui.onNodeWithText("执行结束 · 待验收 · 耗时 12秒 · 10-03 15:20").assertIsDisplayed()
  ui.onNodeWithText("已完成").assertDoesNotExist()
  ui.onNodeWithText("整合并构建").assertDoesNotExist()
  ui.onNodeWithTag("task-summary-toggle-message-finished").performClick()
  ui.onNodeWithText("整合并构建").assertIsDisplayed()
  ui.onNodeWithText("构建已完成，真实使用路径待验收").assertDoesNotExist()
  ui.onNodeWithText("整合并构建").performClick()
  ui.onNodeWithText("构建已完成，真实使用路径待验收").assertIsDisplayed()
  capture("awaiting-verification")
  ui.runOnIdle{verified=true}
  ui.onNodeWithText("验收通过 · 耗时 12秒 · 10-03 15:20").assertIsDisplayed()
  capture("verified")
 }
}
