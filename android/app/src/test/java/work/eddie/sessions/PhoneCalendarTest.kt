package work.eddie.sessions

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class PhoneCalendarTest{
 private val shanghai=ZoneId.of("Asia/Shanghai")
 private val date=LocalDate.of(2026,10,2)
 private fun millis(value:String)=Instant.parse(value).toEpochMilli()
 private fun event(id:Long,start:String,end:String,allDay:Boolean=false)=PhoneCalendarEvent(id,"事件 $id",millis(start),millis(end),allDay)

 @Test fun todayUsesLocalMidnightAndNotTheNext24Hours(){
  val day=phoneCalendarWindow(date,zone=shanghai)
  assertEquals(millis("2026-10-01T16:00:00Z"),day.begin)
  assertEquals(millis("2026-10-02T16:00:00Z"),day.end)
  val early=event(1,"2026-10-01T17:00:00Z","2026-10-01T18:00:00Z")
  val tomorrow=event(2,"2026-10-02T16:00:00Z","2026-10-02T17:00:00Z")
  assertEquals(listOf(1L),phoneCalendarEventsOn(listOf(tomorrow,early),date,shanghai).map{it.id})
 }

 @Test fun dstDaysKeepTheirActualDuration(){
  val ny=ZoneId.of("America/New_York")
  val spring=phoneCalendarWindow(LocalDate.of(2026,3,8),zone=ny)
  val fall=phoneCalendarWindow(LocalDate.of(2026,11,1),zone=ny)
  assertEquals(23L*3_600_000,spring.end-spring.begin)
  assertEquals(25L*3_600_000,fall.end-fall.begin)
 }

 @Test fun allDayUsesUtcDateEvenWestOfUtc(){
  val event=event(1,"2026-10-02T00:00:00Z","2026-10-03T00:00:00Z",true)
  for(zone in listOf(shanghai,ZoneId.of("America/Los_Angeles"))){
   assertTrue(phoneCalendarEventsOn(listOf(event),date,zone).isNotEmpty())
   assertTrue(phoneCalendarEventsOn(listOf(event),date.minusDays(1),zone).isEmpty())
   assertTrue(phoneCalendarEventsOn(listOf(event),date.plusDays(1),zone).isEmpty())
   val window=phoneCalendarWindow(date,zone=zone)
   assertTrue(window.queryBegin<=event.begin&&window.queryEnd>=event.end)
  }
 }

 @Test fun multiDayAllDayHasExclusiveLastDate(){
  val trip=event(1,"2026-10-01T00:00:00Z","2026-10-04T00:00:00Z",true)
  assertTrue(phoneCalendarEventsOn(listOf(trip),date,shanghai).isNotEmpty())
  assertTrue(phoneCalendarEventsOn(listOf(trip),date.plusDays(1),shanghai).isNotEmpty())
  assertTrue(phoneCalendarEventsOn(listOf(trip),date.plusDays(2),shanghai).isEmpty())
 }

 @Test fun overnightOverlapAppearsButMidnightEndDoesNot(){
  val overnight=event(1,"2026-10-01T15:30:00Z","2026-10-01T17:00:00Z")
  val ended=event(2,"2026-10-01T15:00:00Z","2026-10-01T16:00:00Z")
  assertEquals(listOf(1L),phoneCalendarEventsOn(listOf(overnight,ended),date,shanghai).map{it.id})
  assertEquals("跨日",phoneCalendarEventTime(overnight,date,shanghai))
 }

 @Test fun zeroDurationEventIsIncludedOnlyAtItsOwnDate(){
  val point=event(1,"2026-10-01T16:00:00Z","2026-10-01T16:00:00Z")
  assertEquals(1,phoneCalendarEventsOn(listOf(point),date,shanghai).size)
  assertTrue(phoneCalendarEventsOn(listOf(point),date.minusDays(1),shanghai).isEmpty())
 }

 @Test fun hiddenDeclinedAndCancelledEventsAreExcluded(){
  val event=event(1,"2026-10-02T01:00:00Z","2026-10-02T02:00:00Z")
  val events=listOf(event,event.copy(id=2,visible=false),event.copy(id=3,status=2),event.copy(id=4,attendeeStatus=2))
  assertEquals(listOf(1L),phoneCalendarEventsOn(events,date,shanghai).map{it.id})
 }

 @Test fun repeatsDeduplicateByEventAndInstanceStart(){
  val morning=event(1,"2026-10-02T01:00:00Z","2026-10-02T02:00:00Z")
  val evening=event(1,"2026-10-02T12:00:00Z","2026-10-02T13:00:00Z")
  val allDay=event(2,"2026-10-02T00:00:00Z","2026-10-03T00:00:00Z",true)
  val events=phoneCalendarEventsOn(listOf(evening,morning,morning,allDay),date,shanghai)
  assertEquals(listOf(allDay,morning,evening),events)
  assertEquals("全天",phoneCalendarEventTime(allDay,date,shanghai))
  assertEquals("09:00",phoneCalendarEventTime(morning,date,shanghai))
 }
}
