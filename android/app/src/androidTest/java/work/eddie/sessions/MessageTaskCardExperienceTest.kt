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
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import java.io.File

/** 对话内联任务卡：只有派发的后台任务出现，工具步骤与普通问答不出现。 */
class MessageTaskCardExperienceTest {
    @get:Rule val ui = createComposeRule()

    private fun open(): WorkbenchModel {        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        lateinit var vm: WorkbenchModel
        ui.runOnUiThread {
            vm = WorkbenchModel(app)
            vm.active = false
            vm.hermesVisible = false
            vm.updateHermesDraft("")
            vm.hermesOutbox = emptyList(); vm.outgoingMessages.clear()
            vm.hermesSendNote = ""; vm.hermesError = ""; vm.error = ""
            vm.hermesFresh = true; vm.taskLedgerFresh = true; vm.workProposalsFresh = true
            val linked = JSONArray()
                .put(JSONObject().put("id", "job-1").put("kind", "task").put("title", "跑一遍测试").put("status", "running").put("agent", "codex"))
                .put(JSONObject().put("id", "job-2").put("kind", "task").put("title", "整理执行结果").put("status", "running").put("agent", "codex"))
                .put(JSONObject().put("id", "job-3").put("kind", "task").put("title", "更新任务关联").put("status", "queued").put("agent", "codex"))
                .put(JSONObject().put("id", "job-4").put("kind", "task").put("title", "需要核实的账本回执").put("status", "unknown").put("agent", "codex"))
                .put(JSONObject().put("id", "job-5").put("kind", "task").put("title", "已停止的旧事项").put("status", "cancelled").put("agent", "codex"))
            val plain = JSONArray().put(JSONObject().put("id", "tool-1").put("kind", "tool").put("title", "读取源码").put("status", "done"))
            vm.hermes = JSONObject().put("conversation_id", "local-inline-cards").put("runs", JSONArray())
                .put("messages", JSONArray()
                    .put(JSONObject().put("id", "plain-message").put("role", "user").put("text", "这个月餐饮花了多少？").put("status", "completed").put("tasks", plain))
                    .put(JSONObject().put("id", "job-message").put("role", "user").put("text", "帮我跑测试并整理结果").put("status", "delegated")
                        .put("tasks", linked).put("linked_tasks", linked)))
            vm.taskLedger = JSONObject().put("items", JSONArray())
        }
        ui.setContent { MaterialTheme(colorScheme = Palette) { Workbench(vm, "", 0, {}) } }
        if (ui.onAllNodesWithText("完成").fetchSemanticsNodes().isNotEmpty()) ui.onNodeWithText("完成").performClick()
        ui.waitForIdle()
        return vm
    }

    /** 本机证据：内联任务卡在真实消息下的实际渲染。 */
    private fun capture(name: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        ui.waitForIdle()
        ui.mainClock.advanceTimeBy(400)
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        android.os.SystemClock.sleep(300)
        val shot = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(context.getExternalFilesDir(null), "com-m2-$name.png").outputStream().use { shot.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test fun onlyDispatchedJobsGetInlineCards() {
        val vm = open()
        ui.onNodeWithText("这个月餐饮花了多少？").assertIsDisplayed()
        ui.onAllNodesWithTag("message-task-tool-1").assertCountEquals(0)
        ui.onNodeWithText("帮我跑测试并整理结果").assertIsDisplayed()
        for (id in listOf("job-1", "job-2", "job-3")) {
            ui.onNodeWithTag("message-task-$id", useUnmergedTree = true).assertExists()
        }
        ui.onNodeWithTag("message-task-job-5", useUnmergedTree = true).assertExists()
        // 内联卡与工作过程卡现在同处一列，不再互相覆盖。
        ui.onNodeWithTag("agent-work-card-job-message", useUnmergedTree = true).assertExists()
        capture("inline-cards")
        ui.runOnIdle { assertEquals("local-inline-cards", vm.hermes.optString("conversation_id")) }
    }

    @Test fun cardsAboveTheCapCollapseIntoOneEntryThatOpensTheRightFilter() {
        val vm = open()
        ui.onNodeWithTag("message-task-more", useUnmergedTree = true).assertExists()
        ui.onNodeWithText("另有 1 项").assertExists()
        ui.onNodeWithTag("message-task-more", useUnmergedTree = true).performScrollTo().performClick()
        ui.waitForIdle()
        ui.runOnIdle { assertEquals("decision", vm.taskFilter) }
    }

    @Test fun tappingACardOpensThatExactTaskAndKeepsItsMessage() {
        val vm = open()
        val job2 = ui.onNodeWithTag("message-task-job-2", useUnmergedTree = true)
        job2.performScrollTo()
        ui.waitForIdle()
        ui.onNodeWithTag("message-task-job-2", useUnmergedTree = true).performClick()
        ui.waitForIdle()
        ui.runOnIdle {
            assertEquals("job-2", vm.taskDetailId)
            assertEquals("job-message", vm.taskReturnMessageId)
        }
    }
}
