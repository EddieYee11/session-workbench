package work.eddie.sessions
import org.junit.Assert.*
import org.junit.Test
class TranscriptTest {
 @Test fun multipleTurnsKeepEachFinalAnswerAndEverySearchTarget(){
  val roles=listOf("user","assistant","tool","assistant","tool","assistant","user","assistant")
  val rows=transcriptRows(roles,roles.indices.map{it.toString()})
  assertEquals(listOf(listOf(0),listOf(1,2,3,4),listOf(5),listOf(6),listOf(7)),rows.map{it.indices})
  assertTrue(rows[1].process)
  assertEquals(roles.indices.toList(),rows.flatMap{it.indices})
 }
 @Test fun unfinishedToolTurnHasNoFabricatedAnswer(){
  val rows=transcriptRows(listOf("user","assistant","tool"),listOf("u","a","t"))
  assertEquals(listOf(1,2),rows.last().indices);assertTrue(rows.last().process)
 }
 @Test fun plainConversationAndOrphanHistoryRemainReadable(){
  val rows=transcriptRows(listOf("tool","user","assistant"),listOf("t","u","a"))
  assertEquals(3,rows.size);assertTrue(rows.first().process);assertFalse(rows.last().process)
 }
}
