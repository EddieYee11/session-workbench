package work.eddie.sessions

import android.content.Context
import android.graphics.Typeface
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import io.noties.markwon.AbstractMarkwonPlugin
import io.noties.markwon.Markwon
import io.noties.markwon.core.MarkwonTheme
import io.noties.markwon.ext.strikethrough.StrikethroughPlugin
import io.noties.markwon.ext.tables.TablePlugin
import io.noties.markwon.linkify.LinkifyPlugin

/** Application context only: one renderer, no Activity retained across navigation. */
internal object MarkdownRenderer {
 private var instance:Markwon?=null
 @Synchronized fun get(context:Context):Markwon=instance?:Markwon.builder(context.applicationContext)
  .usePlugin(TablePlugin.create(context.applicationContext))
  .usePlugin(StrikethroughPlugin.create()).usePlugin(LinkifyPlugin.create())
  .usePlugin(object:AbstractMarkwonPlugin(){
   override fun configureTheme(builder:MarkwonTheme.Builder){
    builder.headingTextSizeMultipliers(floatArrayOf(1.35f,1.25f,1.15f,1.1f,1f,1f))
   }
  }).build().also{instance=it}
}

private class MarkdownRenderState(var text:String?=null,var font:Float?=null)

@Composable internal fun MarkdownMessage(text:String,font:Float,modifier:Modifier=Modifier,padding:Int=0){
 AndroidView(modifier=modifier.fillMaxWidth(),factory={context->MarkdownTextView(context).apply{
  setTextColor(android.graphics.Color.rgb(20,20,20));setLinkTextColor(android.graphics.Color.rgb(57,108,85))
  typeface=Typeface.create("sans-serif",Typeface.NORMAL);includeFontPadding=false
  setTextIsSelectable(true)
  val inset=(padding*resources.displayMetrics.density).toInt();setPadding(inset,inset,inset,inset)
  tag=MarkdownRenderState()
 }},update={view->
  val state=view.tag as MarkdownRenderState
  if(state.font!=font){
   view.textSize=font
   view.setLineSpacing(font*.42f*view.resources.displayMetrics.scaledDensity,1f)
   state.font=font
  }
  if(state.text!=text){MarkdownRenderer.get(view.context).setMarkdown(view,text);state.text=text}
 })
}
