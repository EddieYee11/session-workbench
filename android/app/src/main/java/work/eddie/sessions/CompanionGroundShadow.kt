package work.eddie.sessions

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate

/** Shared floor plane: softness is elliptical too, rather than a circle clipped to an oval. */
@Composable
internal fun CompanionGroundShadow(
    modifier: Modifier = Modifier,
    compact: Boolean = false,
    turnLift: Float = 0f,
) {
    Canvas(modifier) {
        val lift = turnLift.coerceIn(0f, 1f)
        val radius = size.width * (.25f + lift * .015f)
        val ink = Color(0xFF38303D)
        val strength = (if (compact) .65f else 1f) * (1f - lift * .15f)
        translate(size.width * .5f, size.height * .903f) {
            scale(1f, .15f, pivot = Offset.Zero) {
                drawCircle(
                    brush = Brush.radialGradient(
                        0f to ink.copy(alpha = .12f * strength),
                        .25f to ink.copy(alpha = .105f * strength),
                        .55f to ink.copy(alpha = .052f * strength),
                        .8f to ink.copy(alpha = .013f * strength),
                        1f to Color.Transparent,
                        center = Offset.Zero,
                        radius = radius,
                    ),
                    radius = radius,
                    center = Offset.Zero,
                )
            }
            scale(1f, .10f, pivot = Offset.Zero) {
                drawCircle(
                    brush = Brush.radialGradient(
                        listOf(ink.copy(alpha = .038f * strength), Color.Transparent),
                        center = Offset.Zero,
                        radius = radius * .7f,
                    ),
                    radius = radius * .7f,
                    center = Offset.Zero,
                )
            }
        }
    }
}
