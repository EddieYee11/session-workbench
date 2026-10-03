package work.eddie.sessions

import org.junit.Assert.*
import org.junit.Test

class AgentWorkCardTest {
 @Test fun avatarStatusPrefersConcreteAction(){
  assertEquals("拉取代码",avatarWorkStatus("tool","git_pull"))
  assertEquals("拉取代码",avatarWorkStatus("executing","mcp__git_fetch"))
  assertEquals("开始修改",avatarWorkStatus("tool","file_edit"))
  assertEquals("开始修改",avatarWorkStatus("tool","apply_patch"))
  assertEquals("搜索资料",avatarWorkStatus("tool","web_search"))
 }

 @Test fun avatarStatusFallsBackToPhase(){
  assertEquals("努力思考中",avatarWorkStatus("thinking",""))
  assertEquals("努力工作中",avatarWorkStatus("executing",""))
  assertEquals("正在回复",avatarWorkStatus("streaming",""))
  assertEquals("工作中",avatarWorkStatus("",""))
 }

 @Test fun workEventsFollowPhaseAndTool(){
  assertEquals(AgentWorkEvent("analyze","分析用户请求内容"),agentWorkEventFor("thinking",""))
  assertEquals(AgentWorkEvent("write","正在撰写回复"),agentWorkEventFor("streaming",""))
  assertEquals("正在读取日历与账本概览",agentWorkEventFor("tool","mcp__personal_overview")?.text)
  assertNull(agentWorkEventFor("",""))
 }
}
