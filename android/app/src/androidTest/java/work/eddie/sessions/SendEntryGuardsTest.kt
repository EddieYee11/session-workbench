package work.eddie.sessions

import android.app.Application
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Emulator-only guards: rejected local input must not allocate a pending send. */
class SendEntryGuardsTest {
 private fun model():WorkbenchModel {
  val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
  lateinit var vm:WorkbenchModel
  InstrumentationRegistry.getInstrumentation().runOnMainSync {
   vm=WorkbenchModel(app);vm.active=false;vm.hermesFresh=true
  }
  return vm
 }

 @Test fun unavailableReferenceServicePreservesHermesDraftAndDoesNotAllocateRequest(){
  val vm=model()
  InstrumentationRegistry.getInstrumentation().runOnMainSync {
   vm.hermesPending=JSONObject();vm.messageReferencesAvailable=false
   vm.updateHermesDraft("请解释这段引用")
   vm.hermesReference=JSONObject().put("mode","reply").put("id","source")
   assertNull(vm.sendHermes("guard-reference-request"))
   assertEquals("请解释这段引用",vm.hermesDraft)
   assertNotNull(vm.hermesReference)
   assertTrue(vm.hermesPending.length()==0)
   assertTrue(vm.outgoingMessages.isEmpty())
  }
 }

 @Test fun transcriptionEventIsConsumedOnceAndNeverSendsANewerEditedDraft(){
  val vm=model()
  InstrumentationRegistry.getInstrumentation().runOnMainSync {
   vm.hermesFresh=true;vm.hermesSending=false;vm.hermesVoicePhase="idle"
   vm.hermesVoiceAutoSend="录音转写";vm.updateHermesDraft("用户已经改成的新草稿")
   assertFalse(vm.consumeHermesVoiceSend("录音转写"))
   assertEquals("用户已经改成的新草稿",vm.hermesDraft)
   vm.hermesVoiceAutoSend="第二段转写";vm.updateHermesDraft("第二段转写")
   assertTrue(vm.consumeHermesVoiceSend("第二段转写"))
   assertFalse(vm.consumeHermesVoiceSend("第二段转写"))
  }
 }
}
