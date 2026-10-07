package work.eddie.sessions

import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebSettings
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.json.JSONObject

/** Bundled upstream MIT voice-glow. Only the native 0–1 meter reaches the
 * renderer; microphone capture and transcription stay in Com's own flow. */
@Suppress("UNUSED_PARAMETER")
@Composable internal fun VoiceGlow(level:Float,processing:Boolean,active:Boolean,modifier:Modifier=Modifier,reach:Dp=30.dp){
 val lifecycle=LocalLifecycleOwner.current.lifecycle
 val context=LocalContext.current
 var resumed by remember{mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))}
 val reduce=android.provider.Settings.Global.getFloat(context.contentResolver,android.provider.Settings.Global.ANIMATOR_DURATION_SCALE,1f)==0f
 DisposableEffect(lifecycle){val observer=LifecycleEventObserver{_,_->resumed=lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)};lifecycle.addObserver(observer);onDispose{lifecycle.removeObserver(observer)}}
 val state=rememberUpdatedState(JSONObject().put("level",level.coerceIn(0f,1f)).put("processing",processing).put("active",active&&resumed).put("paused",!active||!resumed||reduce).put("theme","light").toString())
 val holder=remember{arrayOfNulls<WebView>(1)}
 DisposableEffect(Unit){onDispose{holder[0]?.let{it.stopLoading();it.destroy()};holder[0]=null}}
 AndroidView(modifier=modifier,factory={context->object:WebView(context){override fun onTouchEvent(event:android.view.MotionEvent)=false}.apply{
  holder[0]=this
  setBackgroundColor(android.graphics.Color.TRANSPARENT)
  importantForAccessibility=android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO
  isVerticalScrollBarEnabled=false;isHorizontalScrollBarEnabled=false
  settings.javaScriptEnabled=true;settings.blockNetworkLoads=true
  settings.allowContentAccess=false;settings.javaScriptCanOpenWindowsAutomatically=false
  settings.mixedContentMode=WebSettings.MIXED_CONTENT_NEVER_ALLOW
  webViewClient=object:WebViewClient(){
   override fun onPageFinished(view:WebView,url:String){view.evaluateJavascript("window.comVoiceUpdate?.(${state.value})",null)}
   override fun shouldOverrideUrlLoading(view:WebView,request:android.webkit.WebResourceRequest)=true
  }
  isClickable=false;isFocusable=false
  loadUrl("file:///android_asset/VoiceBeam.html")
 }},update={view->view.evaluateJavascript("window.comVoiceUpdate?.(${state.value})",null)})
}
