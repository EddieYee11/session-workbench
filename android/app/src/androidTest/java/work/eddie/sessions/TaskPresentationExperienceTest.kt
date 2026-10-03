package work.eddie.sessions
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
class TaskPresentationExperienceTest {
 @get:Rule val ui=createComposeRule()
 @Test fun completedCallsCollapseButUnfinishedCallRemains(){
  val events=listOf("tool.started" to "a","tool.completed" to "a","tool.started" to "b","tool.completed" to "b","tool.started" to "c").map{(k,id)->JSONObject().put("kind",k).put("text",JSONObject().put("tool","read").put("call_id",id).toString())}
  val rows=humanSteps(events)
  assertEquals(2,rows.size);assertEquals("读取文件 2 次",rows[0].label);assertTrue(rows[1].label.contains("尚未确认"))
 }
 @Test fun remoteFilesOnlyOfferCopyAndHonestPath(){
  ui.setContent{MaterialTheme{Column{ArtifactCards(listOf(JSONObject().put("path","/tmp/report.md")))}}}
  ui.onNodeWithText("report.md").assertIsDisplayed();ui.onNodeWithText("复制").performClick()
  ui.onNodeWithText("远端文件路径").assertExists();ui.onAllNodesWithText("打开").assertCountEquals(0)
 }
 @Test fun httpsLinksOfferRealOpenCopyShare(){
  ui.setContent{MaterialTheme{ArtifactCards(listOf(JSONObject().put("url","https://example.com/report")))}}
  for(text in listOf("打开","复制","分享"))ui.onNodeWithText(text).assertExists()
 }
}
