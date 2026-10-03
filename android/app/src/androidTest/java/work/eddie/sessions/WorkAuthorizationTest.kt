package work.eddie.sessions

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.*
import java.io.File

/** Emulator-only UI fixtures; never invoke approval against a live task. */
class WorkAuthorizationTest {
    @get:Rule val ui = createComposeRule()
    private fun model(fresh: Boolean): WorkbenchModel {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        lateinit var vm: WorkbenchModel
        ui.runOnUiThread {
            vm = WorkbenchModel(app)
            vm.active = false
            vm.store.token = "emulator-ui-fixture"
            vm.workProposalsFresh = fresh
            vm.taskLedgerFresh = fresh
            vm.workProposals = JSONObject().put("items", JSONArray().put(JSONObject()
                .put("id", "pending-A").put("title", "核对记账通道").put("agent", "codex")
                .put("status", "proposed").put("sandbox", "read-only")
                .put("cwd", "/example").put("reason", "只读核对已有工具")
                .put("prompt", "读取现有配置，不修改文件")
                .put("expires_at", System.currentTimeMillis() / 1000.0 + 3600)))
            vm.taskLedger = JSONObject().put("items", JSONArray().put(JSONObject()
                .put("id", "pending-A").put("title", "核对记账通道").put("agent", "codex")
                .put("status", "approval_required").put("sandbox", "read-only").put("cwd", "/example")))
        }
        return vm
    }

    @Test fun pendingAuthorizationIsVisibleAtTopOfTaskPage() {
        val vm = model(true)
        ui.setContent { MaterialTheme(colorScheme = Palette) { TaskActivityPage(vm, {}) } }
        ui.onNodeWithTag("task-filter-decision").assertIsDisplayed()
        ui.onNodeWithTag("task-ledger-pending-A").performClick()
        ui.onNodeWithText("允许并启动").assertIsDisplayed().assertIsEnabled()
        ui.onNodeWithText("拒绝").assertIsDisplayed().assertIsEnabled()
        ui.onNodeWithText("查看完整执行指令").performClick()
        ui.onNodeWithText("交给 Codex 的指令：\n读取现有配置，不修改文件").assertIsDisplayed()
    }

    @Test fun matchingTaskDetailHasItsOwnAuthorizationControls() {
        val vm = model(true)
        ui.setContent { MaterialTheme(colorScheme = Palette) { Column { TaskLedgerSection(vm, emptyList(), emptyList()) } } }
        ui.onNodeWithText("核对记账通道").performClick()
        ui.onNodeWithText("允许并启动").assertIsDisplayed().assertIsEnabled()
        ui.onNodeWithText("拒绝").assertIsDisplayed().assertIsEnabled()
        ui.onNodeWithText("工作任务 · example").assertIsDisplayed()
        ui.onNodeWithText("只读检查").assertDoesNotExist()
    }

    @Test fun workSourceReturnsToConfirmedNativeMessageInsteadOfHiddenMainParent() {
        val vm = model(true)
        val oldBase = vm.store.base
        ui.runOnUiThread {
            vm.store.base = "https://127.0.0.1:9"
            vm.taskLedger = JSONObject().put("items", JSONArray().put(JSONObject()
                .put("id", "native-task").put("title", "工作页交办").put("agent", "codex").put("status", "unknown")
                .put("message_id", "hidden-main-parent").put("source_session_id", "native-source-session")
                .put("source_message_id", "native-source-message")))
            vm.workProposals = JSONObject().put("items", JSONArray())
        }
        try {
            ui.setContent { MaterialTheme(colorScheme = Palette) { Column { TaskLedgerSection(vm, emptyList(), emptyList(), "native-task") } } }
            ui.onNodeWithTag("task-source-native-task").performClick()
            ui.runOnIdle {
                assertEquals("native-source-session", vm.selected)
                assertEquals("native-source-message", vm.targetMessage)
                assertEquals(1, vm.externalWorkRoute)
                assertEquals(0, vm.externalHermesRoute)
            }
        } finally { ui.runOnUiThread { vm.store.prefs.edit().putString("base", oldBase).apply() } }
    }

    @Test fun newWorkAlwaysUsesFullPermissionWithoutRestrictedChoices() {
        val vm = model(false)
        ui.runOnUiThread { vm.connected = false }
        ui.setContent { MaterialTheme(colorScheme = Palette) { NewSession(vm, "codex", {}) } }
        ui.onNodeWithText("高级设置").performClick()
        ui.onNodeWithTag("work-operation-permission").assertIsDisplayed().assertHasNoClickAction()
        ui.onNodeWithText("只读", substring = false).assertDoesNotExist()
        ui.onNodeWithText("工作目录内写入", substring = false).assertDoesNotExist()
        ui.onNodeWithText("Claude", substring = false).performClick()
        ui.onNodeWithTag("work-operation-permission").assertIsDisplayed().assertHasNoClickAction()
        val image = ui.onNodeWithTag("advanced-session-sheet").captureToImage().asAndroidBitmap()
        File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "com-work-full-permission.png").outputStream().use {
            image.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    @Test fun cachedAuthorizationNeverAllowsOfflineExecution() {
        val vm = model(false)
        ui.setContent { MaterialTheme(colorScheme = Palette) { WorkProposalSection(vm, pendingOnly = true) } }
        ui.onNodeWithText("允许并启动").assertIsNotEnabled()
        ui.onNodeWithText("拒绝").assertIsNotEnabled()
        ui.onNodeWithText("离线记录，同步后才能允许或拒绝。").assertIsDisplayed()
    }

    @Test fun mainConversationOffersSameAuthorizationAndRemovesHandledCard() {
        val vm = model(true)
        ui.runOnUiThread {
            vm.hermesFresh = true
            vm.hermes = JSONObject().put("conversation_id", "ui-only").put("messages", JSONArray()
                .put(JSONObject().put("id", "sample").put("role", "assistant")
                    .put("text", "这项操作需要你的授权，请核对下方卡片。").put("status", "completed")))
        }
        ui.setContent { MaterialTheme(colorScheme = Palette) { HermesChat(vm, {}, {}, {}) } }
        ui.onNodeWithText("允许并启动").assertIsDisplayed().assertIsEnabled()
        ui.onNodeWithText("拒绝").assertIsDisplayed().assertIsEnabled()
        ui.runOnUiThread {
            val handled = JSONObject(vm.workProposals.toString())
            handled.getJSONArray("items").getJSONObject(0).put("status", "rejected")
            vm.workProposals = handled
            vm.workProposalNote = "已拒绝这项工作建议"
        }
        ui.onNodeWithText("允许并启动").assertDoesNotExist()
        ui.onNodeWithText("已拒绝这项工作建议").assertIsDisplayed()
    }
}
