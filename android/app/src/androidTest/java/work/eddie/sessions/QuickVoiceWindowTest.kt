package work.eddie.sessions

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.os.SystemClock
import android.provider.Settings
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleCallback
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

/** Opt-in live acceptance: fixture and HTTPS pairing are supplied outside the test APK. */
@RunWith(AndroidJUnit4::class)
class QuickVoiceWindowTest {
 private val instrumentation get()=InstrumentationRegistry.getInstrumentation()

 @Test fun assistWindowTranscribesSendsAndReturnsToPreviousApp(){
  val arguments=InstrumentationRegistry.getArguments()
  assumeTrue("Requires explicit liveQuickVoice=true",arguments.getString("liveQuickVoice")=="true")
  val context=instrumentation.targetContext
  // Store consumes the normal connection.json bootstrap; no credentials enter test code or output.
  val store=Store(context)
  assertTrue("Prepare a paired HTTPS connection before this live test",store.base.startsWith("https://")&&store.token.isNotBlank())
  val capture=arguments.getString("capture")?.trim()
   ?:store.prefs.getString("quick-voice-file",null)?.removeSuffix(".m4a")
  require(capture!=null&&capture.matches(Regex("[a-f0-9-]{36}"))){"Pass capture=<UUID> for the prepared audio fixture"}
  val captureFile=File(context.filesDir,"quick-voice/$capture.m4a")
  arguments.getString("fixture")?.let{name->
   require(name.matches(Regex("[a-z0-9_-]+\\.m4a"))){"Fixture must be a local audio filename"}
   val fixture=File(context.getExternalFilesDir(null),name)
   assertTrue("Prepare the fixture in the app's external files directory",fixture.length()>=512)
   captureFile.parentFile?.mkdirs();fixture.copyTo(captureFile,overwrite=true)
  }
  assertTrue("Prepare files/quick-voice/<capture>.m4a before this live test",captureFile.length()>=512)

  val mainWasOpened=AtomicBoolean(false)
  val monitor=ActivityLifecycleMonitorRegistry.getInstance()
  val callback=ActivityLifecycleCallback{activity,stage->
   if(activity is MainActivity&&stage==Stage.RESUMED)mainWasOpened.set(true)
  }
  monitor.addLifecycleCallback(callback)
  var activity:QuickVoiceActivity?=null
  try{
   launchFromSystem("am start -a android.settings.SETTINGS")
   await(10_000,"Settings did not become the foreground app"){
    resumedActivities().any{it.contains("com.android.settings/")}
   }
   val settingsTask=Regex("\\bt(\\d+)\\b").find(resumedActivities().first{it.contains("com.android.settings/")})
    ?.groupValues?.get(1)?.toInt()
   assertNotNull("Could not identify the previous app's task",settingsTask)
   // Launch through the system surface; a background app launch is a different Xiaomi permission.
   launchFromSystem("am start -a android.intent.action.ASSIST -n work.eddie.sessions/.QuickVoiceActivity")
   await(10_000,"ASSIST did not open QuickVoiceActivity"){
    activity=onMain{monitor.getActivitiesInStage(Stage.RESUMED).filterIsInstance<QuickVoiceActivity>().firstOrNull()}
    activity!=null
   }
   val window=checkNotNull(activity)
   val model=onMain{ViewModelProvider(window)[QuickVoiceModel::class.java]}
   await(10_000,"Assistant small window did not start recording"){
    assertFalse("ASSIST must not navigate to Com main",mainWasOpened.get())
    onMain{model.phase=="recording"&&window.window.decorView.height>0}
   }
   onMain{
    val decor=window.window.decorView
    val screenHeight=window.resources.displayMetrics.heightPixels
    val location=IntArray(2);decor.getLocationOnScreen(location)
    assertTrue("ASSIST must use a small window, not a full-screen page",decor.height<screenHeight*.65f)
    assertTrue("The panel must leave the previous app visible",location[1]>screenHeight*.15f)
    assertTrue("The panel must stay anchored near the bottom",location[1]+decor.height>screenHeight*.85f)
    assertTrue("ASSIST must retain the previous app's task",window.taskId!=settingsTask)
    assertTrue("ASSIST must use the conversation flow, not expense parsing",model.conversationMode)
   }
   // Layout can be measured before the entrance animation reaches the compositor.
   // Give the reused companion WebView and panel a few frames before capturing pixels.
   SystemClock.sleep(800)
   screenshot("listening")
   onMain{
    // Stop physical recording, then exercise the existing transcribe/send pipeline with the fixture.
    model.cancelRecording()
    check(store.prefs.edit().putString("quick-voice-file","$capture.m4a").commit())
    model.transcribe()
   }
   await(120_000,"Quick voice did not receive a durable Pi handoff receipt"){
    assertFalse("Quick voice must never navigate to Com main",mainWasOpened.get())
    onMain{
     if(model.phase=="ready"||model.phase=="confirm")fail("Quick voice failed: ${model.message}")
     model.phase=="sent"
    }
   }
   assertTrue("The real ASR pipeline must return recognized text",onMain{model.transcript.isNotBlank()})
   val receiptFile=File(context.filesDir,"quick-voice/$capture.quickvoice.json")
   assertTrue("Pi handoff must survive closing the window",receiptFile.exists())
   val receipt=JSONObject(receiptFile.readText())
   assertEquals("pi",receipt.getString("agent"))
   assertEquals("quickvoice-$capture",receipt.getString("request_id"))
   assertEquals(onMain{model.transcript},receipt.getString("text"))
   assertTrue("A handoff receipt must not declare an uncertain send successful",piVoiceAccepted(receipt.getString("status")))
   await(10_000,"Quick voice did not dismiss and restore Settings"){
    onMain{window.isDestroyed}&&resumedActivities().any{it.contains("com.android.settings/")}
   }
   assertFalse("No Com main page may appear during the entire flow",mainWasOpened.get())
   assertFalse("The foreground app must not be Com main",resumedActivities().any{it.contains("/work.eddie.sessions.MainActivity")||it.contains("/.MainActivity")})
   screenshot("returned")
  }finally{
   monitor.removeLifecycleCallback(callback)
   activity?.let{window->onMain{if(!window.isDestroyed){ViewModelProvider(window)[QuickVoiceModel::class.java].cancelConversationCapture();window.finish()}}}
  }
 }

 private fun <T> onMain(block:()->T):T{
  val result=AtomicReference<T>()
  instrumentation.runOnMainSync{result.set(block())}
  return result.get()
 }

 private fun await(timeout:Long,message:String,condition:()->Boolean){
  val deadline=SystemClock.elapsedRealtime()+timeout
  while(!condition()){
   if(SystemClock.elapsedRealtime()>=deadline)fail(message)
   SystemClock.sleep(100)
  }
 }

 private fun launchFromSystem(command:String){
  android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command))
   .bufferedReader().use{it.readText()}
 }

 private fun resumedActivities():List<String>{
  val output=android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand("dumpsys activity activities"))
   .bufferedReader().use{it.readText()}
  return output.lineSequence().filter{it.contains("topResumedActivity=")||it.contains("mResumedActivity:")}.toList()
 }

 private fun screenshot(state:String){
  val output=File(instrumentation.targetContext.getExternalFilesDir(null),"quickvoice-live-$state.png")
  val bitmap=instrumentation.uiAutomation.takeScreenshot()
  output.outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
 }
}
