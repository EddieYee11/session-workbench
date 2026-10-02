package work.eddie.sessions

import org.junit.Assert.assertEquals
import org.junit.Test

class PersonalConversationTest {
 @Test fun financeMinorUnitsAreDisplayedWithoutLosingCents(){
  assertEquals("CNY 1,234.56",formatMinorAmount(123456,"CNY"))
  assertEquals("CNY 0.01",formatMinorAmount(1,"CNY"))
 }

 @Test fun uncertainMessageStatusIsExplicit(){
  assertEquals("结果待核实 · 不会自动重发",hermesMessageStatus("unknown"))
  assertEquals("处理失败",hermesMessageStatus("failed"))
 }

 @Test fun streamedStatusUsesOnlyPersistedServerPhase(){
  assertEquals("",hermesPhaseStatus(""))
  assertEquals("已接收",hermesPhaseStatus("received"))
  assertEquals("正在思考",hermesPhaseStatus("thinking"))
  assertEquals("正在执行",hermesPhaseStatus("executing"))
  assertEquals("正在回复",hermesPhaseStatus("responding"))
  assertEquals("回复结束",hermesPhaseStatus("completed"))
 }
}
