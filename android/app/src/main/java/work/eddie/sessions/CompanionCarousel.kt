package work.eddie.sessions

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/** Two permanent faces share a spindle; neither leaves a rectangular viewport or gets replaced. */
@Composable
fun CompanionCarousel(agent: String, state: String, interactive: Boolean, compact: Boolean) {
    val density = LocalDensity.current
    val angle by animateFloatAsState(
        targetValue = if (agent == "codex") 180f else 0f,
        animationSpec = spring(dampingRatio = .72f, stiffness = 210f),
        label = "伙伴背靠背旋转",
    )
    val radians = angle * PI.toFloat() / 180f
    val turn = abs(sin(radians))
    val side = turn * turn
    val progress = ((1f - cos(radians)) / 2f).coerceIn(0f, 1f)

    Box(Modifier.fillMaxSize()) {
        // This plane never inherits the faces' 3D transforms or their blur.
        CompanionGroundShadow(Modifier.fillMaxSize(), compact, side)

        // Only the brief edge-on interval needs a curved silhouette behind the
        // artwork. Its soft highlight avoids a blank frame without adding a card.
        Canvas(Modifier.fillMaxSize()) {
            if (side > .001f) {
                val center = Offset(size.width * .5f, size.height * .565f)
                val radius = size.width * (if (compact) .293f else .255f)
                val surface = lerp(Color(0xFFE8E4F1), Color(0xFF819BDF), progress)
                scale(.73f - side * .53f, 1f - side * .025f, pivot = center) {
                    drawCircle(
                        brush = Brush.radialGradient(
                            0f to lerp(surface, Color.White, .34f),
                            .5f to surface,
                            .85f to lerp(surface, Color(0xFF484667), .12f),
                            1f to surface.copy(alpha = 0f),
                            center = center + Offset(-radius * .12f, -radius * .13f),
                            radius = radius * 1.12f,
                        ),
                        radius = radius,
                        center = center,
                        alpha = side * side * side,
                    )
                }
            }
        }

        // Stable call sites keep the WebView and plush mesh alive through reversal.
        for (who in listOf("pi", "codex")) {
            val rotation = (if (who == "codex") 180f else 0f) - angle
            val facing = cos(rotation * PI.toFloat() / 180f)
            val visibility = (facing / .22f).coerceIn(0f, 1f)
            val faceAlpha = visibility * visibility * (3f - 2f * visibility)
            val active = who == agent && facing > .65f
            val blur = with(density) { (side * 1.3f).dp.toPx() }
            val accessibility = if (active) Modifier else Modifier.clearAndSetSemantics { }
            Box(
                Modifier.fillMaxSize().zIndex(facing).then(accessibility).graphicsLayer {
                    rotationY = rotation
                    transformOrigin = TransformOrigin(.5f, .565f)
                    cameraDistance = size.width * 8f
                    // The spring's overshoot naturally reverses the deformation at rest.
                    scaleX = 1f + sin(radians * 2f) * .024f
                    scaleY = 1f - side * .038f
                    translationY = -size.height * side * .012f
                    rotationZ = sin(radians * 2f) * 1.5f
                    alpha = faceAlpha
                    clip = false
                    renderEffect = if (blur > .2f) BlurEffect(blur, blur * .45f, TileMode.Decal) else null
                },
            ) {
                CompanionAvatar(
                    agent = who,
                    state = if (who == agent) state else "idle",
                    modifier = Modifier.fillMaxSize(),
                    interactive = interactive && active,
                    compact = compact,
                    showGroundShadow = false,
                    nativeAnimationActive = facing > 0f || side > .002f,
                )
            }
        }
    }
}
