package com.wiqo.android.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans

enum class WiqoPillKind {
    Accent, Secondary, Ghost
}

@Composable
fun WiqoCard(
    modifier: Modifier = Modifier,
    radius: Dp = WiqoDesign.CardRadius,
    padding: Dp = 16.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = WiqoDesign.colors
    val shape = RoundedCornerShape(radius)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .shadow(
                elevation = 6.dp,
                shape = shape,
                ambientColor = Color.Black.copy(alpha = 0.05f),
                spotColor = Color.Black.copy(alpha = 0.05f),
            )
            .background(colors.surface, shape)
            .border(0.5.dp, colors.line, shape)
            .padding(padding),
        content = content,
    )
}

@Composable
fun WiqoPillButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: WiqoPillKind = WiqoPillKind.Secondary,
    enabled: Boolean = true,
    isLoading: Boolean = false,
    height: Dp = 40.dp,
    shape: Shape = RoundedCornerShape(percent = 50),
) {
    val colors = WiqoDesign.colors
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (isPressed) 0.96f else 1f,
        animationSpec = tween(140),
        label = "pill_scale",
    )

    val backgroundColor = when (kind) {
        WiqoPillKind.Accent -> colors.ink
        WiqoPillKind.Secondary -> colors.surface
        WiqoPillKind.Ghost -> Color.Transparent
    }

    val foregroundColor = when (kind) {
        WiqoPillKind.Accent -> colors.systemBackground
        WiqoPillKind.Secondary -> colors.ink
        WiqoPillKind.Ghost -> colors.ink.copy(alpha = 0.6f)
    }

    val borderModifier = if (kind == WiqoPillKind.Secondary) {
        Modifier.border(0.5.dp, colors.line, shape)
    } else Modifier

    Box(
        modifier = modifier
            .scale(scale)
            .height(height)
            .clip(shape)
            .background(backgroundColor, shape)
            .then(borderModifier)
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                enabled = enabled && !isLoading,
                onClick = onClick,
            )
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        if (isLoading) {
            CircularProgressIndicator(
                modifier = Modifier.size(18.dp),
                color = foregroundColor,
                strokeWidth = 2.dp,
            )
        } else {
            Text(
                text = text,
                color = foregroundColor,
                fontFamily = WiqoSans,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}

@Composable
fun WiqoActionButton(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: WiqoPillKind = WiqoPillKind.Accent,
    isLoading: Boolean = false,
    enabled: Boolean = true,
) {
    WiqoPillButton(
        text = title,
        onClick = onClick,
        modifier = modifier.fillMaxWidth(),
        kind = kind,
        enabled = enabled,
        isLoading = isLoading,
        height = 48.dp,
    )
}

@Composable
fun WiqoField(
    modifier: Modifier = Modifier,
    isFocused: Boolean = false,
    hasError: Boolean = false,
    content: @Composable () -> Unit,
) {
    val colors = WiqoDesign.colors
    val borderColor by animateColorAsState(
        targetValue = when {
            hasError -> colors.red.copy(alpha = 0.7f)
            isFocused -> colors.ink.copy(alpha = 0.5f)
            else -> Color.Transparent
        },
        animationSpec = tween(200),
        label = "field_border",
    )
    val shape = RoundedCornerShape(WiqoDesign.FieldRadius)

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(48.dp)
            .background(colors.inset, shape)
            .border(1.5.dp, borderColor, shape)
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        content()
    }
}

@Composable
fun WiqoCheckbox(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = WiqoDesign.colors
    val shape = RoundedCornerShape(6.dp)
    val interactionSource = remember { MutableInteractionSource() }

    Box(
        modifier = modifier
            .size(22.dp)
            .clip(shape)
            .background(if (checked) colors.ink else colors.inset, shape)
            .border(1.dp, if (checked) Color.Transparent else colors.lineStrong, shape)
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                onClick = { onCheckedChange(!checked) },
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (checked) {
            Icon(
                imageVector = Icons.Default.Check,
                contentDescription = null,
                tint = colors.systemBackground,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

@Composable
fun RovaActionTile(
    title: String,
    icon: ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = WiqoDesign.colors.ink,
    isDestructive: Boolean = false,
) {
    val colors = WiqoDesign.colors
    val shape = RoundedCornerShape(WiqoDesign.ChipRadius)
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (isPressed) 0.96f else 1f,
        animationSpec = tween(140),
        label = "tile_scale",
    )

    Column(
        modifier = modifier
            .scale(scale)
            .size(width = 84.dp, height = 76.dp)
            .shadow(4.dp, shape, ambientColor = Color.Black.copy(alpha = 0.04f))
            .background(colors.surface, shape)
            .border(0.5.dp, colors.line, shape)
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            )
            .padding(horizontal = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (isDestructive) colors.red else tint,
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = title,
            fontFamily = WiqoSans,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = colors.ink,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
fun RovaConnectionIcon(
    isPaired: Boolean,
    isConnected: Boolean,
    isConnecting: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val colors = WiqoDesign.colors
    val inkColor = colors.ink
    val dotColor = when {
        !isPaired -> colors.ink.copy(alpha = 0.4f)
        isConnecting -> colors.orange
        isConnected -> colors.green
        else -> colors.ink.copy(alpha = 0.4f)
    }

    Box(
        modifier = modifier.size(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.foundation.Canvas(modifier = Modifier.size(22.dp, 16.dp)) {
            val strokeWidth = 1.6.dp.toPx()
            val screenW = 16.dp.toPx()
            val screenH = 10.dp.toPx()
            val screenLeft = (size.width - screenW) / 2f
            val screenTop = 2.dp.toPx()

            // Laptop Screen
            drawRoundRect(
                color = inkColor,
                topLeft = androidx.compose.ui.geometry.Offset(screenLeft, screenTop),
                size = androidx.compose.ui.geometry.Size(screenW, screenH),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.5.dp.toPx()),
                style = androidx.compose.ui.graphics.drawscope.Stroke(width = strokeWidth),
            )

            // Laptop Base
            val baseW = 20.dp.toPx()
            val baseLeft = (size.width - baseW) / 2f
            val baseY = screenTop + screenH + 1.2.dp.toPx()
            drawLine(
                color = inkColor,
                start = androidx.compose.ui.geometry.Offset(baseLeft, baseY),
                end = androidx.compose.ui.geometry.Offset(baseLeft + baseW, baseY),
                strokeWidth = strokeWidth * 1.1f,
                cap = androidx.compose.ui.graphics.StrokeCap.Round,
            )

            // Status dot at top-right of the screen
            val dotRadius = 2.2.dp.toPx()
            drawCircle(
                color = dotColor,
                radius = dotRadius,
                center = androidx.compose.ui.geometry.Offset(screenLeft + screenW + 1.5.dp.toPx(), screenTop - 1.dp.toPx()),
            )
        }
    }
}
