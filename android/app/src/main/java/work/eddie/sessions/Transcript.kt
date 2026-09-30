package work.eddie.sessions

/** A turn keeps its latest answer prominent and puts the preceding work behind one disclosure. */
data class TranscriptRow(val key:String,val indices:List<Int>,val process:Boolean)
fun transcriptRows(roles:List<String>,ids:List<String>):List<TranscriptRow>{
 val rows=mutableListOf<TranscriptRow>();val turn=mutableListOf<Int>()
 fun flush(){
  if(turn.isEmpty())return
  val answer=turn.last().takeIf{roles[it]=="assistant"}
  val work=turn.filter{it!=answer}
  if(work.isNotEmpty())rows.add(TranscriptRow("process:"+ids[work.first()],work.toList(),true))
  if(answer!=null)rows.add(TranscriptRow(ids[answer],listOf(answer),false))
  turn.clear()
 }
 roles.indices.forEach{i->if(roles[i]=="user"){flush();rows.add(TranscriptRow(ids[i],listOf(i),false))}else turn.add(i)}
 flush();return rows
}
