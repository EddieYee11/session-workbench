package work.eddie.sessions

import android.text.Spanned
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import android.text.style.ClickableSpan
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class MarkdownMessageTest {
 @get:Rule val ui=createComposeRule()
 @Test fun headingsBoldCodeListsTablesLinksAndStreamingUpdates(){
  val text=mutableStateOf("## 检查结果\n\n**已完成**，`代码`\n\n- 第一项\n- 第二项\n\n[链接](https://example.com)\n\n```python\nprint(1)\n```\n\n| 项目 | 状态 |\n| --- | --- |\n| 主页 | 完成 |")
  ui.setContent{MaterialTheme(colorScheme=Palette,typography=ComTypography){Column{MarkdownMessage(text.value,16f)}}}
  ui.waitForIdle()
  InstrumentationRegistry.getInstrumentation().runOnMainSync{
   val context=InstrumentationRegistry.getInstrumentation().targetContext
   val renderer=MarkdownRenderer.get(context)
   assertSame(renderer,MarkdownRenderer.get(context))
   val rendered=renderer.toMarkdown(text.value)
   assertTrue(rendered is Spanned)
   assertFalse(rendered.toString().contains("**"))
   assertFalse(rendered.toString().contains("```"))
   assertTrue(rendered.getSpans(0,rendered.length,MetricAffectingSpan::class.java).any{span->
    val paint=TextPaint();span.updateMeasureState(paint);paint.isFakeBoldText||paint.typeface?.isBold==true
   })
   assertTrue(rendered.getSpans(0,rendered.length,ClickableSpan::class.java).isNotEmpty())
  }
  ui.runOnUiThread{text.value+="\n\n追加的实时回复"}
  ui.waitForIdle()
  val screenshot=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
  val context=InstrumentationRegistry.getInstrumentation().targetContext
  java.io.File(context.getExternalFilesDir(null),"com161-markdown.png").outputStream().use{
   screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)
  }
 }
}
