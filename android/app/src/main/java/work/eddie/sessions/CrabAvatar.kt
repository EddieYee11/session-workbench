package work.eddie.sessions

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * 像素螃蟹：按用户提供的像素螃蟹形象，用像素网格程序化绘制的虚拟形象。
 *
 * Shape supplied in avatar-crab.bundle, commit 8dc57c97fb5daeb6b69321f5a2e0df03af3ffff5.
 * Drawn locally with Compose Canvas; no image download, WebView, or native bridge.
 * Caller-owned task state is the only source of completion feedback.
 *
 * 状态：idle / listening / thinking / working / speaking / success / error / offline
 */
object CrabAvatarState {
    const val IDLE = "idle"
    const val LISTENING = "listening"
    const val THINKING = "thinking"
    const val WORKING = "working"
    const val SPEAKING = "speaking"
    const val SUCCESS = "success"
    const val ERROR = "error"
    const val OFFLINE = "offline"

    fun normalize(raw: String): String = when (raw.trim().lowercase()) {
        IDLE, LISTENING, THINKING, WORKING, SPEAKING, SUCCESS, ERROR, OFFLINE -> raw.trim().lowercase()
        "task_completed", "verified_success" -> SUCCESS
        "responding" -> SPEAKING
        "greeting", "happy", "done", "completed", "cancelled" -> IDLE
        "failed" -> ERROR
        "running", "executing", "delivering" -> WORKING
        else -> IDLE
    }

    fun defaultCopy(state: String): String = when (normalize(state)) {
        IDLE -> "在呢，随时叫我"
        LISTENING -> "听着呢…"
        THINKING -> "想想啊…"
        WORKING -> "正在努力干活…"
        SPEAKING -> "说给你听"
        SUCCESS -> "搞定！"
        ERROR -> "出现问题"
        OFFLINE -> "离线了，稍后再试"
        else -> "在呢，随时叫我"
    }
}

private object CrabPalette {
    val body = Color(0xFFDD7757)      // 珊瑚橙
    val shade = Color(0xFFC05F42)      // 暗部
    val outline = Color(0xFFFFFFFF)    // 贴纸白边
    val ink = Color(0xFF1A1A1A)
    val sparkle = Color(0xFFFFD66B)
    val wave = Color(0xFFE8936B)
    val offlineBody = Color(0xFF9AA0A3)
    val offlineShade = Color(0xFF7E8487)
}

// 像素小图：'X' = 前景色
private val PIXEL_QUESTION = listOf(
    ".XXX.",
    "X...X",
    "....X",
    "...X.",
    "..X..",
    ".....",
    "..X..",
)
private val PIXEL_Z = listOf(
    "XXXX",
    "...X",
    "..X.",
    ".X..",
    "XXXX",
)
private val PIXEL_SPARKLE = listOf(
    "..X..",
    "..X..",
    "XXXXX",
    "..X..",
    "..X..",
)
private val PIXEL_NOTE = listOf(
    "..XX",
    "..X.",
    "..X.",
    ".XX.",
    "XXX.",
    "XX..",
)

private fun DrawScope.drawPixelMap(
    map: List<String>,
    origin: Offset,
    px: Float,
    color: Color,
) {
    map.forEachIndexed { row, line ->
        line.forEachIndexed { col, ch ->
            if (ch == 'X') {
                drawRect(
                    color,
                    topLeft = Offset(origin.x + col * px, origin.y + row * px),
                    size = Size(px, px),
                )
            }
        }
    }
}

@Composable
fun CrabAvatarWithStatus(
    state: String,
    modifier: Modifier = Modifier,
    statusText: String? = null,
    reducedMotion: Boolean = false,
    avatarSize: Dp = 200.dp,
) {
    val s = CrabAvatarState.normalize(state)
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        CrabAvatar(
            state = s,
            modifier = Modifier.size(avatarSize)
                .semantics { contentDescription = "螃蟹 ${CrabAvatarState.defaultCopy(s)}" },
            reducedMotion = reducedMotion,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            text = statusText ?: CrabAvatarState.defaultCopy(s),
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.alpha(if (s == CrabAvatarState.OFFLINE) 0.55f else 1f),
        )
    }
}

@Composable
fun CrabAvatar(
    state: String,
    modifier: Modifier = Modifier,
    reducedMotion: Boolean = false,
    isAnimationActive: Boolean = true,
    compact: Boolean = false,
) {
    val s = CrabAvatarState.normalize(state)
    val moving = isAnimationActive && !reducedMotion
    // Removing the transition from composition freezes all loops while offscreen,
    // paused, or when Android has disabled animations. A static state still reads.
    val motion = if (moving) crabMotion(s) else CrabMotion(0f, false)
    val phase = motion.phase
    val blinking = motion.blinking && s != CrabAvatarState.OFFLINE
    val targetTilt = when (s) {
        CrabAvatarState.LISTENING -> -4f
        CrabAvatarState.THINKING -> -8f
        CrabAvatarState.ERROR -> 7f
        CrabAvatarState.WORKING -> 10f
        else -> 0f
    }
    val tilt = if (moving) {
        val animated by animateFloatAsState(
            targetTilt,
            spring(dampingRatio = .82f, stiffness = 320f),
            label = "crab tilt",
        )
        animated
    } else targetTilt

    val grey = s == CrabAvatarState.OFFLINE
    val body = if (grey) CrabPalette.offlineBody else CrabPalette.body
    val shade = if (grey) CrabPalette.offlineShade else CrabPalette.shade
    val outline = CrabPalette.outline
    val ink = CrabPalette.ink

    Canvas(modifier) {
        // Full size reserves top room for the thought bubble / error mark.
        // Compact avatars keep the supplied silhouette legible without tiny symbols.
        val grid = if (compact) 24f else 30f
        val px = size.minDimension / grid
        val ox = (size.width - 22f * px) / 2f
        val oy = (size.height - (if (compact) 20f else 30f) * px) / 2f +
            (if (compact) 0f else 6f) * px
        fun X(v: Float) = ox + v * px
        fun Y(v: Float) = oy + v * px

        // 像素风位移：取整，保证抖动是整像素
        val bobSteps = if (!moving) 0 else when (s) {
            CrabAvatarState.SUCCESS -> (sin(phase) * (if (compact) 1f else 2f)).roundToInt()
            CrabAvatarState.WORKING -> (sin(phase) * 1.5f).roundToInt()
            CrabAvatarState.OFFLINE -> (sin(phase) * 0.5f).roundToInt()
            else -> (sin(phase) * 1f).roundToInt()
        }
        val bobPx = bobSteps * px
        // 跟随弹跳的矩形（含白边）；地面阴影单独画，不跟随
        fun rect(color: Color, x: Float, y: Float, w: Float, h: Float) {
            drawRect(
                color,
                topLeft = Offset(X(x), Y(y) + bobPx),
                size = Size(w * px, h * px),
            )
        }

        // 地面阴影
        if (!grey) {
            drawRect(
                Color.Black.copy(alpha = 0.10f),
                topLeft = Offset(X(5f), Y(19f)),
                size = Size(12f * px, 1f * px),
            )
        }

        rotate(tilt, Offset(X(11f), Y(10f))) {
            fun YY(v: Float) = Y(v) + bobPx

            // ---- 手臂（success 时上举） ----
            val armUp = s == CrabAvatarState.SUCCESS
            val armY = if (armUp) 3f else 8f
            // 左臂
            rect(outline, 0f, armY, 3f, 5f); rect(body, 1f, armY + 1f, 2f, 3f)
            // 右臂
            rect(outline, 19f, armY, 3f, 5f); rect(body, 19f, armY + 1f, 2f, 3f)

            // ---- 身体白边 + 本体 ----
            rect(outline, 2f, 1f, 18f, 14f)
            // 腿的白边（先画，与身体连成一体）
            listOf(4f, 10f, 16f).forEach { lx ->
                rect(outline, lx, 13f, 4f, 6f)
            }
            // 本体
            drawRect(body, topLeft = Offset(X(3f), YY(2f)), size = Size(16f * px, 12f * px))
            // 暗部：底部与右侧各一条
            drawRect(shade, topLeft = Offset(X(3f), YY(12f)), size = Size(16f * px, 2f * px))
            drawRect(shade, topLeft = Offset(X(17f), YY(2f)), size = Size(2f * px, 12f * px))
            // 腿
            listOf(4f, 10f, 16f).forEach { lx ->
                drawRect(body, topLeft = Offset(X(lx + 1f), YY(14f)), size = Size(2f * px, 4f * px))
            }

            // ---- 眼睛 ----
            val eyeH = if (blinking) 1f else 2f
            val lookX = when (s) {
                CrabAvatarState.LISTENING -> 1f
                CrabAvatarState.THINKING -> 1f
                else -> 0f
            }
            val eyeY = if (s == CrabAvatarState.THINKING) 4f else 5f
            if (grey) {
                // 离线：闭眼横线
                drawRect(ink, Offset(X(6f), YY(eyeY + 1f)), Size(2f * px, 1f * px))
                drawRect(ink, Offset(X(14f), YY(eyeY + 1f)), Size(2f * px, 1f * px))
            } else {
                drawRect(ink, Offset(X(6f + lookX), YY(eyeY)), Size(2f * px, eyeH * px))
                drawRect(ink, Offset(X(14f + lookX), YY(eyeY)), Size(2f * px, eyeH * px))
            }

            // ---- 嘴 ----
            when {
                grey ->
                    drawRect(ink, Offset(X(10f), YY(11f)), Size(4f * px, 1f * px))
                s == CrabAvatarState.SPEAKING && moving && sin(phase * 2f) > 0f ->
                    drawRect(ink, Offset(X(10f), YY(10f)), Size(4f * px, 3f * px)) // 张嘴
                s == CrabAvatarState.SPEAKING ->
                    drawRect(ink, Offset(X(10f), YY(11f)), Size(4f * px, 1f * px)) // 闭嘴
                s == CrabAvatarState.SUCCESS ->
                    drawRect(ink, Offset(X(9f), YY(10f)), Size(6f * px, 3f * px)) // 大笑
                s == CrabAvatarState.ERROR -> {
                    // 撇嘴
                    drawRect(ink, Offset(X(9f), YY(11f)), Size(1f * px, 1f * px))
                    drawRect(ink, Offset(X(10f), YY(10f)), Size(3f * px, 1f * px))
                    drawRect(ink, Offset(X(13f), YY(11f)), Size(1f * px, 1f * px))
                }
                s == CrabAvatarState.THINKING ->
                    drawRect(ink, Offset(X(10f), YY(11f)), Size(4f * px, 1f * px))
                else -> {
                    // 微笑
                    drawRect(ink, Offset(X(9f), YY(10f)), Size(1f * px, 1f * px))
                    drawRect(ink, Offset(X(10f), YY(11f)), Size(4f * px, 1f * px))
                    drawRect(ink, Offset(X(14f), YY(10f)), Size(1f * px, 1f * px))
                }
            }

            // ---- 状态装饰 ----
            if (!compact) {
                when (s) {
                    CrabAvatarState.LISTENING -> {
                        // 像素声波：右侧三列竖条，高度呼吸
                        val p = if (moving) (sin(phase * 2f) * 0.5f + 0.5f) else .5f
                        (0..2).forEach { i ->
                            val h = 2f + i * 2f + p * 1.5f
                            drawRect(
                                CrabPalette.wave,
                                Offset(X(19.5f + i * 1.2f), YY(8f - h / 2f)),
                                Size(1f * px, h * px),
                            )
                        }
                    }
                    CrabAvatarState.THINKING -> {
                        // 像素气泡
                        val p = if (moving) (sin(phase) * 0.5f + 0.5f) else .5f
                        drawRect(CrabPalette.wave, Offset(X(15f), YY(0f - p)), Size(3f * px, 2f * px))
                        drawRect(CrabPalette.wave, Offset(X(13f), YY(2.5f - p * 0.5f)), Size(1f * px, 1f * px))
                    }
                    CrabAvatarState.WORKING -> {
                        // 像素速度线
                        (0..2).forEach { i ->
                            val w = 3f + ((sin(phase * 3f + i * 2f) * 0.5f + 0.5f) * 3f)
                            drawRect(
                                CrabPalette.wave.copy(alpha = 0.7f),
                                Offset(X(0.5f), YY(6f + i * 3f)),
                                Size(w * px, 1f * px),
                            )
                        }
                    }
                    CrabAvatarState.SPEAKING -> {
                        val p = if (moving) (sin(phase) * 0.5f + 0.5f) else .5f
                        drawPixelMap(PIXEL_NOTE, Offset(X(20f), YY(4f - p * 2f)), px, CrabPalette.wave)
                    }
                    CrabAvatarState.SUCCESS -> {
                        val spots = listOf(
                            Offset(X(1f), YY(2f)), Offset(X(20f), YY(3f)),
                            Offset(X(3f), YY(14f)), Offset(X(18f), YY(15f)),
                        )
                        spots.forEachIndexed { i, o ->
                            if (!moving || (sin(phase * 2f + i) * 0.5f + 0.5f) > 0.35f) {
                                drawPixelMap(PIXEL_SPARKLE, o, px * 0.8f, CrabPalette.sparkle)
                            }
                        }
                    }
                    CrabAvatarState.ERROR -> {
                        drawPixelMap(PIXEL_QUESTION, Offset(X(17f), YY(-4f)), px * 1.2f, CrabPalette.wave)
                    }
                    CrabAvatarState.OFFLINE -> {
                        val z = if (moving) (sin(phase * 0.8f) * 0.5f + 0.5f) else 0f
                        drawPixelMap(PIXEL_Z, Offset(X(18f), YY(-3f - z * 2f)), px, CrabPalette.wave.copy(alpha = 0.8f))
                        drawPixelMap(PIXEL_Z, Offset(X(20f), YY(-3.5f - z * 1.5f)), px * 0.7f, CrabPalette.wave.copy(alpha = 0.5f))
                    }
                    else -> Unit
                }
            }
        }
    }
}

private data class CrabMotion(val phase: Float, val blinking: Boolean)

@Composable
private fun crabMotion(state: String): CrabMotion {
    val transition = rememberInfiniteTransition(label = "crab motion")
    val loopSpeed = when (state) {
        CrabAvatarState.WORKING -> 900
        CrabAvatarState.SUCCESS -> 850
        CrabAvatarState.LISTENING -> 1400
        CrabAvatarState.OFFLINE -> 4000
        else -> 2400
    }
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = (2 * PI).toFloat(),
        animationSpec = infiniteRepeatable(tween(loopSpeed, easing = LinearEasing), RepeatMode.Restart),
        label = "crab phase",
    )
    val blink by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(4200, easing = LinearEasing), RepeatMode.Restart),
        label = "crab blink",
    )
    return CrabMotion(phase, blink in 0.925f..0.965f)
}
