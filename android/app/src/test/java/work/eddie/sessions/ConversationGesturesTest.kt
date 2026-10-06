package work.eddie.sessions

import org.junit.Assert.*
import org.junit.Test

class ConversationGesturesTest {
 @Test fun readingHistoryHidesHeaderAndDismissesImeAfterThreshold(){
  val state=ConversationGestures()
  assertEquals(0,state.drag(10f,60f,true,2f))
  assertEquals(-10f,state.headerOffset,0f)
  assertFalse(state.consumesBottomPull(10f))
  assertEquals(-1,state.drag(15f,60f,true,2f))
  assertEquals(0,state.drag(100f,60f,false,2f))
  assertEquals(-60f,state.headerOffset,0f)
 }
 @Test fun latestDirectionOnlyOpensImeAfterFurtherBottomDrag(){
  val state=ConversationGestures()
  repeat(20){assertEquals(0,state.drag(-10f,60f,false,2f))}
  assertFalse(state.consumesBottomPull(-10f))
  assertEquals(0,state.drag(-30f,60f,true,2f))
  assertTrue(state.consumesBottomPull(-10f))
  assertEquals(1,state.drag(-45f,60f,true,2f))
  assertEquals(0,state.drag(-50f,60f,true,2f))
  assertEquals(-1,state.drag(30f,60f,false,2f))
  assertFalse(state.consumesBottomPull(30f))
 }
}
