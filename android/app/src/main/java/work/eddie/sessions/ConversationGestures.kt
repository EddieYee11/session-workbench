package work.eddie.sessions

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.runtime.*
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.unit.Velocity
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest

/** Only direct vertical drags drive the header/IME; flings and automatic scrolling do not. */
@Composable internal fun rememberConversationGestures(list:LazyListState,headerHeightPx:Float=0f,canType:Boolean=true,focus:FocusRequester?=null):ConversationGestures{
 val keyboard=LocalSoftwareKeyboardController.current
 val density=LocalDensity.current.density
 val keyboardVisible by rememberUpdatedState(WindowInsets.ime.getBottom(LocalDensity.current)>0)
 val state=remember(focus){ConversationGestures(focus?:FocusRequester())}
 val height by rememberUpdatedState(headerHeightPx)
 val enabled by rememberUpdatedState(canType)
 val ime by rememberUpdatedState(keyboard)
 state.connection=remember(list,density){object:NestedScrollConnection{
  override fun onPreScroll(available:Offset,source:NestedScrollSource):Offset{
   if(source==NestedScrollSource.UserInput){
    val action=state.drag(available.y,height,!list.canScrollForward&&!keyboardVisible&&enabled,density)
    if(action<0){state.skipViewportAnchor=true;ime?.hide()}
    else if(action>0&&enabled){state.keepLatestOnResize=true;state.focusRequester.requestFocus();ime?.show()}
   }
   // A pull starting at latest raises the IME in place; normal/history drags keep their full distance.
   return if(source==NestedScrollSource.UserInput&&state.consumesBottomPull(available.y))Offset(0f,available.y)else Offset.Zero
  }
  override suspend fun onPostFling(consumed:Velocity,available:Velocity):Velocity{
   state.endDrag();return Velocity.Zero
  }
 }}
 // Keep resize anchoring out of a dismissing drag until native IME size frames settle.
 LaunchedEffect(state,list){snapshotFlow{Triple(state.skipViewportAnchor,state.keepLatestOnResize,list.layoutInfo.viewportSize.height) to keyboardVisible}.collectLatest{(frame,visible)->
  val(skip,keep,_)=frame
  if(skip||keep&&visible){delay(180);state.skipViewportAnchor=false;if(visible)state.keepLatestOnResize=false}
 }}
 return state
}

internal class ConversationGestures(val focusRequester:FocusRequester=FocusRequester()){
 var headerOffset by mutableFloatStateOf(0f)
 var skipViewportAnchor by mutableStateOf(false)
 var keepLatestOnResize by mutableStateOf(false)
 var connection:NestedScrollConnection=object:NestedScrollConnection{}
 private var upDistance=0f
 private var bottomPull=0f
 private var pullingFromLatest=false
 private var hidden=false
 private var shown=false
 fun drag(delta:Float,height:Float,atBottom:Boolean,density:Float):Int{
  headerOffset=(headerOffset+delta).coerceIn(-height.coerceAtLeast(0f),0f)
  if(delta<0){
   bottomPull=0f;pullingFromLatest=false;keepLatestOnResize=false;shown=false;upDistance-=delta
   if(!hidden&&upDistance>=12f*density){hidden=true;return -1}
  }else if(delta>0){
   upDistance=0f;hidden=false
   if(bottomPull==0f&&!shown)pullingFromLatest=atBottom
   if(pullingFromLatest){bottomPull+=delta;if(!shown&&bottomPull>=36f*density){shown=true;return 1}}
   else{bottomPull=0f;shown=false}
  }
  return 0
 }
 fun consumesBottomPull(delta:Float)=delta>0&&(pullingFromLatest||keepLatestOnResize)
 fun endDrag(){upDistance=0f;bottomPull=0f;pullingFromLatest=false;hidden=false;shown=false}
}
