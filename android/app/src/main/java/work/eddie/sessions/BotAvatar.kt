package work.eddie.sessions

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.database.ContentObserver
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.json.JSONObject
import java.io.ByteArrayInputStream

/**
 * The supplied Grok 灵动助手 v2, rendered entirely from bundled assets.
 * Keep the canvas square: the sphere occupies about half the canvas width.
 * Repeated state values do not replay one-shot happy / greeting feedback.
 * Unknown states (including upload without a real progress source) become idle.
 */
@Composable
fun BotAvatar(
    state: String,
    modifier: Modifier = Modifier,
    interactive: Boolean = true,
) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var webView by remember { mutableStateOf<BotAvatarWebView?>(null) }

    DisposableEffect(webView, lifecycle) {
        val view = webView
        val observer = LifecycleEventObserver { _, _ ->
            view?.setRunning(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        }
        lifecycle.addObserver(observer)
        view?.setRunning(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        onDispose {
            lifecycle.removeObserver(observer)
            view?.setRunning(false)
        }
    }

    AndroidView(
        modifier = modifier.aspectRatio(1f),
        factory = { context -> BotAvatarWebView(context).also { webView = it } },
        onReset = null,
        onRelease = { view ->
            view.disposeBot()
            if (webView === view) webView = null
        },
        update = { view ->
            view.updateBot(state, interactive)
            view.setRunning(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        },
    )
}

@SuppressLint("SetJavaScriptEnabled")
private class BotAvatarWebView(context: Context) : WebView(context) {
    private var ready = false
    private var disposed = false
    private var running = false
    private var state = "idle"
    private var interactive = true
    private var reducedMotion = !ValueAnimator.areAnimatorsEnabled()
    private var lastPayload: String? = null
    private val motionObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) = refreshReducedMotion()
    }

    init {
        setBackgroundColor(Color.TRANSPARENT)
        isVerticalScrollBarEnabled = false
        isHorizontalScrollBarEnabled = false
        overScrollMode = OVER_SCROLL_NEVER
        setOnLongClickListener { true }
        isLongClickable = false
        settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = false
            databaseEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            blockNetworkLoads = true
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            setSupportZoom(false)
            displayZoomControls = false
            mediaPlaybackRequiresUserGesture = true
        }
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true

            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                val uri = request.url
                val file = uri.path?.removePrefix("/")
                if (request.method != "GET" || !isLocal(uri) || file !in FILES) {
                    return emptyResponse(403, "Forbidden")
                }
                return try {
                    val mime = when (file?.substringAfterLast('.')) {
                        "html" -> "text/html"
                        "css" -> "text/css"
                        "js" -> "application/javascript"
                        else -> "text/plain"
                    }
                    WebResourceResponse(
                        mime, "UTF-8", 200, "OK",
                        mapOf("Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff"),
                        context.assets.open("grok-bot/$file"),
                    )
                } catch (_: Exception) {
                    emptyResponse(404, "Not Found")
                }
            }

            override fun onPageFinished(view: WebView, url: String) {
                if (disposed || url != PAGE) return
                ready = true
                lastPayload = null
                syncBot()
            }
        }
        context.contentResolver.registerContentObserver(
            Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, motionObserver,
        )
        loadUrl(PAGE)
    }

    fun updateBot(value: String, allowInteraction: Boolean) {
        if (disposed) return
        state = value.takeIf { it in STATES } ?: "idle"
        interactive = allowInteraction
        syncBot()
    }

    fun setRunning(value: Boolean) {
        if (disposed) return
        refreshReducedMotion()
        if (running == value) return
        running = value
        if (running) {
            onResume()
            syncBot()
        } else {
            syncBot()
            onPause()
        }
    }

    private fun refreshReducedMotion() {
        if (disposed) return
        val next = !ValueAnimator.areAnimatorsEnabled()
        if (reducedMotion == next) return
        reducedMotion = next
        syncBot()
    }

    private fun syncBot() {
        if (!ready || disposed) return
        val payload = JSONObject()
            .put("state", state)
            .put("interactive", interactive)
            .put("reducedMotion", reducedMotion)
            .put("running", running)
            .toString()
        if (payload == lastPayload) return
        lastPayload = payload
        evaluateJavascript("window.WorkbenchBot && window.WorkbenchBot.update($payload);", null)
    }

    fun disposeBot() {
        if (disposed) return
        if (ready) evaluateJavascript("window.WorkbenchBot && window.WorkbenchBot.dispose();", null)
        disposed = true
        ready = false
        context.contentResolver.unregisterContentObserver(motionObserver)
        stopLoading()
        onPause()
        removeAllViews()
        destroy()
    }

    companion object {
        private const val HOST = "grok-bot.local"
        private const val PAGE = "https://$HOST/index.html"
        private val STATES = setOf("idle", "listening", "thinking", "speaking", "error", "happy", "greeting", "curious")
        private val FILES = setOf("index.html", "host.css", "host.js", "bot-data.js", "bot-controller.js", "grok-bot.js", "vendor/lottie.min.js")
        private fun isLocal(uri: Uri) = uri.scheme == "https" && uri.host == HOST && uri.port == -1 && uri.query == null
        private fun emptyResponse(status: Int, reason: String) =
            WebResourceResponse("text/plain", "UTF-8", status, reason, emptyMap(), ByteArrayInputStream(ByteArray(0)))
    }
}
