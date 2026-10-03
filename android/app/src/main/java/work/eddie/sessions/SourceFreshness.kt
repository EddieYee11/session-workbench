package work.eddie.sessions

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** A source can have saved data without having confirmed the current empty result. */
enum class ReadPhase { NotLoaded, Loading, Synced, Cached, Failed }
data class SourceReadState(val phase:ReadPhase,val lastSuccess:Double=0.0){
 val current get()=phase==ReadPhase.Synced
 val saved get()=lastSuccess>0 || phase==ReadPhase.Cached
 val timeLabel get()=if(lastSuccess>0)Instant.ofEpochMilli((lastSuccess*1000).toLong()).atZone(ZoneId.of("Asia/Shanghai")).format(DateTimeFormatter.ofPattern("M/d HH:mm")) else "时间未记录"
 fun count(count:Int,label:String)=when{
  current->"$count 件$label"
  saved->"上次记录 $count 件$label"
  phase==ReadPhase.Loading->"正在核对$label"
  phase==ReadPhase.Failed->"暂未核实$label"
  else->"尚未读取$label"
 }
}
fun sourceReadState(fresh:Boolean,loading:Boolean,hasData:Boolean,lastSuccess:Double,error:String)=SourceReadState(
 when {fresh->ReadPhase.Synced;hasData->ReadPhase.Cached;loading->ReadPhase.Loading;error.isNotBlank()->ReadPhase.Failed;else->ReadPhase.NotLoaded},lastSuccess)
internal fun todayReadState(vm:WorkbenchModel):SourceReadState{
 val sources=listOf(
  sourceReadState(vm.hermesFresh,vm.hermesLoading,vm.hermes.has("messages"),vm.hermes.optDouble("synced_at",0.0),vm.hermesError),
  sourceReadState(vm.taskLedgerFresh,vm.workProposalsLoading,vm.taskLedger.has("items"),vm.taskLedger.optDouble("synced_at",0.0),vm.taskLedgerError),
  sourceReadState(vm.workProposalsFresh,vm.workProposalsLoading,vm.workProposals.has("items"),vm.workProposals.optDouble("synced_at",0.0),vm.workProposalsError))
 val last=sources.map{it.lastSuccess}.filter{it>0}.minOrNull()?:0.0
 return SourceReadState(when{
  sources.all{it.current}->ReadPhase.Synced
  sources.any{it.saved}->ReadPhase.Cached
  sources.any{it.phase==ReadPhase.Loading}->ReadPhase.Loading
  sources.any{it.phase==ReadPhase.Failed}->ReadPhase.Failed
  else->ReadPhase.NotLoaded},last)
}
