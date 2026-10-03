package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONObject

/** 每条消息下直接展开的任务卡上限；其余合并成一行入口。 */
private const val INLINE_TASK_LIMIT = 3

/** 已结束的分组不占展开位，折叠成一行。 */
private val ENDED_GROUPS = setOf("done", "ended")

internal data class InlineTaskPlan(
    val cards: List<LedgerTask>,
    val ended: List<LedgerTask>,
    val hidden: Int,
    /** 被折叠的条目对应的任务页筛选，便于点开后看到同一批。 */
    val hiddenFilter: String,
)

/**
 * 对话内联卡只收真正派发的后台任务（`message.linked_tasks`）。
 * 同一轮内的工具步骤仍由 `AgentWorkCard` 呈现，普通问答两者都不出现。
 */
internal fun inlineTaskRecords(message: JSONObject): List<JSONObject> =
    message.array("linked_tasks").filter { it.optString("id").isNotBlank() }

internal fun planInlineTasks(tasks: List<LedgerTask>): InlineTaskPlan {
    val live = tasks.filter { ledgerGroup(it) !in ENDED_GROUPS }
    val ended = tasks.filter { ledgerGroup(it) in ENDED_GROUPS }
    val cards = live.take(INLINE_TASK_LIMIT)
    val dropped = live.drop(INLINE_TASK_LIMIT)
    val filter = if (dropped.any { ledgerGroup(it) == "decision" }) "decision" else "active"
    return InlineTaskPlan(cards, ended, dropped.size, filter)
}

@Composable fun MessageTaskCards(
    message: JSONObject,
    taskFresh: Boolean,
    openTask: (String) -> Unit,
    openFilter: (String) -> Unit,
) {
    val tasks = buildLedgerTasks(inlineTaskRecords(message), emptyList())
    if (tasks.isEmpty()) return
    val plan = planInlineTasks(tasks)
    Column(Modifier.fillMaxWidth().padding(top = 4.dp)) {
        plan.cards.forEach { task -> MessageTaskRow(task, taskFresh, openTask) }
        plan.ended.forEach { task -> MessageTaskRow(task, taskFresh, openTask) }
        if (plan.hidden > 0) {
            TextButton(onClick = { openFilter(plan.hiddenFilter) }, modifier = Modifier.fillMaxWidth().testTag("message-task-more")) {
                Text("另有 ${plan.hidden} 项", fontSize = Type.Caption)
            }
        }
    }
}

@Composable private fun MessageTaskRow(task: LedgerTask, taskFresh: Boolean, openTask: (String) -> Unit) {
    val group = ledgerGroup(task)
    val needsYou = group == "decision"
    Surface(
        onClick = { openTask(task.id) },
        modifier = Modifier.fillMaxWidth().padding(top = 6.dp).testTag("message-task-${task.id}"),
        shape = RoundedCornerShape(Radii.L),
        color = if (needsYou) AmberBg else Card,
        border = BorderStroke(1.dp, if (needsYou) AmberLine else Line),
    ) {
        Row(Modifier.padding(horizontal = 14.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
            when (group) {
                "active" -> StatusDot(PiGreen)
                "done" -> Icon(Icons.Outlined.Check, null, Modifier.size(15.dp), tint = PiGreen)
                "ended" -> Box(Modifier.size(6.dp).background(Faint, CircleShape))
                else -> Box(Modifier.size(6.dp).background(if (needsYou) AmberText else Ink, CircleShape))
            }
            Text(
                task.title,
                Modifier.weight(1f).padding(start = 9.dp),
                fontSize = Type.BodySm,
                fontWeight = FontWeight.Medium,
                color = Ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                when {
                    group == "done" -> "查看过程"
                    !taskFresh -> "上次同步：${task.statusText}"
                    else -> task.statusText
                },
                Modifier.padding(start = 8.dp),
                fontSize = Type.Caption,
                color = if (needsYou) AmberText else Muted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            ComIcon(R.drawable.com_icon_chevron_v1, null, Modifier.padding(start = 4.dp).size(16.dp))
        }
    }
}

internal fun supplementAction(state:String):String=when(state){
 "accepted","pending_start","queued"->"改为新事项"
 "revoked"->"已撤销"
 else->"另开新事项"
}
@Composable fun SupplementCards(vm:WorkbenchModel,message:JSONObject){
 val mid=message.optString("id")
 if(mid.isBlank())return
 vm.taskLedger.array("items").forEach{task->
  val sources=task.optJSONObject("input_sources")?:JSONObject()
  task.array("inputs").filter{sources.optString(it.optString("request_id"))==mid}.forEach{input->
   val state=input.optString("state")
   Column(Modifier.fillMaxWidth().padding(top=6.dp)){
    Text("已补充到「${task.optString("title") }」 · ${ledgerDeliveryLabel(state)}",fontSize=Type.Caption,color=Muted)
    if(state !in setOf("accepted","pending_start","queued","revoked"))Text("原任务可能已收到这条补充，无法撤回",fontSize=Type.Micro,color=AmberText)
    if(state!="revoked")TextButton(onClick={vm.moveSupplement(task.optString("id"),input.optString("request_id"))},enabled=vm.taskLedgerFresh&&vm.taskControlBusy.isBlank()){
     Text(supplementAction(state),fontSize=Type.Caption)
    }
   }
  }
 }
}
