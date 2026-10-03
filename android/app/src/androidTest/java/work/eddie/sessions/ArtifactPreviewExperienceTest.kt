package work.eddie.sessions

import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test
import java.io.File

class ArtifactPreviewExperienceTest{
 @get:Rule val ui=createComposeRule()
 @Test fun actualMiniPdfRendersInTheNativePreview(){
  val instrument=InstrumentationRegistry.getInstrumentation()
  val context=instrument.targetContext
  val file=File(context.cacheDir,"Com-1.9.0-mobile-acceptance.pdf")
  instrument.context.assets.open("mobile-acceptance.pdf").use{input->file.outputStream().use{input.copyTo(it)}}
  ui.setContent{MaterialTheme(colorScheme=Palette){ArtifactPreview(file){}}}
  ui.waitUntil(10000){ui.onAllNodesWithContentDescription(file.name).fetchSemanticsNodes().isNotEmpty()}
  ui.onNodeWithContentDescription(file.name).assertIsDisplayed()
  ui.onNodeWithText("关闭").assertIsDisplayed()
  ui.waitForIdle();ui.mainClock.advanceTimeBy(300);instrument.waitForIdleSync();android.os.SystemClock.sleep(350)
  val screenshot=instrument.uiAutomation.takeScreenshot()
  File(context.getExternalFilesDir(null),"com19-pdf-preview.png").outputStream().use{screenshot.compress(Bitmap.CompressFormat.PNG,100,it)}
 }
 @Test fun chineseMarkdownFileCanBeReadWithoutAnotherApp(){
  val context=InstrumentationRegistry.getInstrumentation().targetContext
  val file=File(context.cacheDir,"中文成果.md").apply{writeText("中文成果可直接阅读和选择")}
  ui.setContent{MaterialTheme(colorScheme=Palette){ArtifactPreview(file){}}}
  ui.waitUntil(5000){ui.onAllNodesWithText("中文成果可直接阅读和选择").fetchSemanticsNodes().isNotEmpty()}
  ui.onNodeWithText("中文成果可直接阅读和选择").assertIsDisplayed()
 }
}
