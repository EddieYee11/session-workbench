package work.eddie.sessions
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ClickableSpan
import android.view.*
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MarkdownTextViewTest{
 @Test fun selectableMarkdownLinkOpensOnTapButNotLongPressOrScroll(){
  InstrumentationRegistry.getInstrumentation().runOnMainSync{
   val context=InstrumentationRegistry.getInstrumentation().targetContext
   val v=MarkdownTextView(context);v.layoutParams=android.view.ViewGroup.LayoutParams(800,500);var opened=0
   val content=SpannableString("中文链接 OpenAI")
   content.setSpan(object:ClickableSpan(){override fun onClick(widget:View){opened++}},5,11,Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
   v.text=content;v.setTextIsSelectable(true)
   v.measure(View.MeasureSpec.makeMeasureSpec(800,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(500,View.MeasureSpec.EXACTLY));v.layout(0,0,800,500)
   val x=v.layout.getPrimaryHorizontal(7);val y=v.layout.getLineBottom(0)/2f
   fun touch(action:Int,time:Long,px:Float=x){val e=MotionEvent.obtain(1000,time,action,px,y,0);v.onTouchEvent(e);e.recycle()}
   touch(MotionEvent.ACTION_DOWN,1000);touch(MotionEvent.ACTION_UP,1100);assertEquals(1,opened)
   touch(MotionEvent.ACTION_DOWN,1000);touch(MotionEvent.ACTION_UP,2000);assertEquals(1,opened)
   touch(MotionEvent.ACTION_DOWN,1000);touch(MotionEvent.ACTION_MOVE,1050,x+100);touch(MotionEvent.ACTION_UP,1100,x+100);assertEquals(1,opened)
  }
 }
}
