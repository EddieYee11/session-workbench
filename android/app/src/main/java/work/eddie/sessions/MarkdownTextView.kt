package work.eddie.sessions

import android.content.Context
import android.text.Spanned
import android.text.style.ClickableSpan
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.widget.TextView
import kotlin.math.abs

/** Preserve long-press selection, but let a short tap on a Markdown link activate it. */
class MarkdownTextView(context:Context):TextView(context){
 private var downX=0f;private var downY=0f;private var downAt=0L;private var candidate:ClickableSpan?=null
 private fun linkAt(event:MotionEvent):ClickableSpan?{
  val layout=layout?:return null;val value=text as? Spanned?:return null
  val x=event.x-totalPaddingLeft+scrollX;val y=event.y-totalPaddingTop+scrollY
  if(y<0||y>=layout.height)return null
  val line=layout.getLineForVertical(y.toInt())
  if(x<layout.getLineLeft(line)||x>layout.getLineRight(line))return null
  val offset=layout.getOffsetForHorizontal(line,x)
  return value.getSpans(offset,offset,ClickableSpan::class.java).firstOrNull()
 }
 override fun onTouchEvent(event:MotionEvent):Boolean{
  when(event.actionMasked){
   MotionEvent.ACTION_DOWN->{downX=event.x;downY=event.y;downAt=event.eventTime;candidate=linkAt(event)}
   MotionEvent.ACTION_CANCEL->candidate=null
   MotionEvent.ACTION_UP->{
    val link=candidate;candidate=null
    val slop=ViewConfiguration.get(context).scaledTouchSlop
    if(link!=null&&link===linkAt(event)&&event.eventTime-downAt<ViewConfiguration.getLongPressTimeout()&&abs(event.x-downX)<slop&&abs(event.y-downY)<slop){
     val cancel=MotionEvent.obtain(event);cancel.action=MotionEvent.ACTION_CANCEL;super.onTouchEvent(cancel);cancel.recycle()
     link.onClick(this);return true
    }
   }
  }
  return super.onTouchEvent(event)
 }
}
