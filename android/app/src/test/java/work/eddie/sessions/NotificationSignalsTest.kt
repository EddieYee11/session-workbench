package work.eddie.sessions

import org.junit.Assert.*
import org.junit.Test

class NotificationSignalsTest{
 @Test fun defaultScopeIsRestrictedToWeChatAndSms(){
  assertTrue(signalPackageAllowed("com.tencent.mm","work.eddie.sessions",null,"messages"))
  assertTrue(signalPackageAllowed("com.example.sms","work.eddie.sessions","com.example.sms","messages"))
  assertFalse(signalPackageAllowed("com.example.email","work.eddie.sessions",null,"messages"))
  assertFalse(signalPackageAllowed("work.eddie.sessions","work.eddie.sessions",null,"all"))
  assertFalse(signalPackageAllowed("com.android.systemui","work.eddie.sessions",null,"all"))
 }

 @Test fun sensitiveSignalsAreSkippedBeforeQueueing(){
  assertTrue(signalIsSensitive("微信","验证码 123456，五分钟内有效"))
  assertTrue(signalIsSensitive("Security code","Your one-time password is 123456"))
  assertTrue(signalIsSensitive("短信","123456，五分钟内有效"))
  assertTrue(signalIsSensitive("银行提醒","信用卡还款已到账"))
  assertFalse(signalIsSensitive("朋友","周六下午一起吃饭吗"))
 }

 @Test fun eventIdIsStableAndAcknowledgementCannotDeleteUnsentEvents(){
  val first=signalId("com.tencent.mm","key",123456789L,"朋友","你好")
  assertEquals(first,signalId("com.tencent.mm","key",123456789L,"朋友","你好"))
  assertEquals(64,first.length)
  assertTrue(first.matches(Regex("[a-f0-9]{64}")))
  assertNotEquals(first,signalId("com.tencent.mm","key",123456790L,"朋友","你好"))
  assertEquals(setOf(first),signalAckIds(setOf(first),setOf(first),emptySet()))
  assertNull(signalAckIds(setOf(first),setOf("other"),emptySet()))
 }

 @Test fun importantReminderStartsWithBaselineAndOnlyAlertsOnce(){
  val old=setOf("old")
  assertTrue(newImportantSignalIds(false,emptySet(),old).isEmpty())
  assertTrue(newImportantSignalIds(true,old,old).isEmpty())
  assertEquals(setOf("new"),newImportantSignalIds(true,old,old+"new"))
 }
}
