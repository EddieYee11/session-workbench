package work.eddie.sessions

import org.junit.Assert.*
import org.junit.Test

class AgentWorkCardTest {
 @Test fun avatarStatusPrefersConcreteAction(){
  assertEquals("正在使用 git_pull",avatarWorkStatus("tool","git_pull"))
  assertEquals("正在使用 mcp__git_fetch",avatarWorkStatus("executing","mcp__git_fetch"))
  assertEquals("正在使用 file_edit",avatarWorkStatus("tool","file_edit"))
  assertEquals("正在使用 apply_patch",avatarWorkStatus("tool","apply_patch"))
  assertEquals("正在使用 web_search",avatarWorkStatus("tool","web_search"))
 }

 @Test fun avatarStatusFallsBackToPhase(){
  assertEquals("正在分析用户请求",avatarWorkStatus("thinking",""))
  assertEquals("正在执行工具 · 等待名称",avatarWorkStatus("executing",""))
  assertEquals("正在撰写回复",avatarWorkStatus("streaming",""))
  assertEquals("状态待同步",avatarWorkStatus("",""))
  assertEquals("等待开始",avatarWorkStatus("queued","stale_git_pull"))
  assertEquals("离线记录",avatarWorkStatus("offline","stale_edit"))
 }
 @Test fun phaseAfterToolsDoesNotPretendToAnalyzeTheOriginalRequest(){
  assertEquals("正在分析工具结果",avatarWorkStatus("thinking","",true))
  assertEquals("正在使用 Bash · 执行命令",avatarWorkStatus("executing","bash"))
  assertEquals("正在撰写回复",avatarWorkStatus("streaming","stale_bash",true))
  assertEquals("正在使用 Group",avatarWorkStatus("tool","Group"))
 }
 @Test fun executionAndAcceptanceRemainSeparate(){
  assertEquals("执行结束 · 待验收",agentTaskStatusText("done"))
  assertEquals("工具已执行",agentTaskStatusText("done","tool"))
  assertEquals("已验收",agentTaskStatusText("execution_finished","task","passed"))
  for(status in listOf("done","completed","execution_finished"))assertEquals("执行结束 · 待验收",summaryStatusText(status))
  assertEquals("验收通过",summaryStatusText("done","passed"))
  assertEquals("结果待核实",summaryStatusText("unknown"))
  assertEquals("状态待核实",summaryStatusText("future"))
 }
 @Test fun queuedFollowupCannotHideTheTurnActuallyRunning(){
  val ids=listOf("actual-running-turn","new-queued-followup")
  val states=listOf("running" to "executing","queued" to "queued")
  assertEquals("actual-running-turn",ids[avatarActiveMessageIndex(states)!!])
  assertEquals(0,avatarActiveMessageIndex(listOf("running" to "responding","sending" to "received")))
  assertEquals(1,avatarActiveMessageIndex(listOf("completed" to "completed","queued" to "queued")))
  assertNull(avatarActiveMessageIndex(listOf("completed" to "executing","unknown" to "unknown")))
 }

 @Test fun historicalUnknownCannotKeepTheCompanionUncertain(){
  val completed=listOf("unknown" to "unknown","completed" to "completed")
  assertEquals(HermesAvatarActivity("idle"),hermesAvatarActivity(completed,listOf("unknown","completed")))
  assertEquals(HermesAvatarActivity("idle"),hermesAvatarActivity(emptyList(),listOf("unknown")))
  assertEquals(HermesAvatarActivity("unknown"),hermesAvatarActivity(listOf("completed" to "completed","unknown" to "unknown"),emptyList()))
 }

 @Test fun actuallyRunningWorkerPrecedesQueuedOrUncertainMessages(){
  val tasks=listOf("unknown","running")
  assertEquals(HermesAvatarActivity("worker",workerIndex=1),hermesAvatarActivity(listOf("unknown" to "unknown","queued" to "queued"),tasks))
  assertEquals(HermesAvatarActivity("worker",workerIndex=1),hermesAvatarActivity(listOf("unknown" to "unknown"),tasks))
  assertEquals(HermesAvatarActivity("message",messageIndex=0),hermesAvatarActivity(listOf("running" to "executing","queued" to "queued"),tasks))
 }

 @Test fun appendedOldUnmatchedMessageCannotBecomeTheLatestUnknown(){
  val displayed=listOf("completed" to "completed","unknown" to "unknown")
  assertEquals(HermesAvatarActivity("idle"),hermesAvatarActivity(displayed,emptyList(),listOf(200.0,100.0)))
  assertEquals(HermesAvatarActivity("unknown"),hermesAvatarActivity(displayed,emptyList(),listOf(100.0,200.0)))
  assertEquals(HermesAvatarActivity("unknown"),hermesAvatarActivity(displayed,emptyList()))
  assertEquals(HermesAvatarActivity("worker",workerIndex=0),hermesAvatarActivity(displayed,listOf("running"),listOf(200.0,100.0)))
 }

 @Test fun workEventsFollowPhaseAndTool(){
  assertEquals(AgentWorkEvent("analyze","分析用户请求内容"),agentWorkEventFor("thinking",""))
  assertEquals(AgentWorkEvent("write","正在撰写回复"),agentWorkEventFor("streaming",""))
  assertEquals("正在读取日历与账本概览",agentWorkEventFor("tool","mcp__personal_overview")?.text)
  assertNull(agentWorkEventFor("",""))
 }
 @Test fun legacyPhasesNeverBecomeTasksAwaitingAcceptance(){
  assertEquals("phase",agentWorkKind("think","task"))
  assertEquals("phase",agentWorkKind("reply","tool"))
  assertEquals("task",agentWorkKind("real-task","task"))
  assertEquals("已处理",agentTaskStatusText("done","phase",id="think"))
  assertEquals("回复已生成",agentTaskStatusText("done","phase",id="reply"))
  assertEquals("本轮处理结束",summaryStatusText("execution_finished","unverified"))
  assertEquals("执行结束 · 待验收",summaryStatusText("execution_finished","pending"))
  assertEquals("工具调用失败 · bookkeeping",agentEventDisplayText("正在使用 bookkeeping","failed"))
  assertEquals("工具结果待核实 · bookkeeping",agentEventDisplayText("正在使用 bookkeeping","unknown"))
 }
 @Test fun missingRunIdentityCannotAcceptAWritingCopy(){
  assertFalse(workspaceDeliveryAccepted("workspace-write",true,"",""))
  assertFalse(workspaceDeliveryAccepted("workspace-write",true,"null","null"))
  assertFalse(workspaceDeliveryAccepted("workspace-write",true,"run-a","run-b"))
  assertTrue(workspaceDeliveryAccepted("workspace-write",true,"run-a","run-a"))
  assertTrue(workspaceDeliveryAccepted("read-only",false,"",""))
 }
}
