package com.wiqo.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoMono
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun WiqoCodeBlock(
    code: String,
    title: String,
    modifier: Modifier = Modifier,
    isDiff: Boolean = false,
    onRun: (() -> Void)? = null,
) {
    val colors = WiqoDesign.colors
    val clipboardManager = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    var copied by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(14.dp)

    val lines = remember(code) { code.lines() }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .shadow(6.dp, shape, ambientColor = Color.Black.copy(alpha = 0.05f))
            .clip(shape)
            .background(colors.surface, shape)
            .border(0.5.dp, colors.line, shape),
    ) {
        // Header
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = Icons.Default.Code,
                contentDescription = null,
                tint = colors.ink3,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = title,
                fontFamily = WiqoMono,
                fontSize = 12.sp,
                fontWeight = FontWeight.Normal,
                color = colors.ink,
                modifier = Modifier.weight(1f),
            )
            if (onRun != null) {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = ripple(bounded = true),
                            onClick = { onRun() },
                        )
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Default.PlayArrow,
                        contentDescription = "Çalıştır",
                        tint = colors.ink.copy(alpha = 0.6f),
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = "Çalıştır",
                        fontFamily = WiqoMono,
                        fontSize = 12.sp,
                        color = colors.ink.copy(alpha = 0.6f),
                    )
                }
            }
            Box(
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = ripple(bounded = false, radius = 16.dp),
                        onClick = {
                            clipboardManager.setText(AnnotatedString(code))
                            copied = true
                            scope.launch {
                                delay(1500)
                                copied = false
                            }
                        },
                    )
                    .padding(4.dp),
            ) {
                Icon(
                    imageVector = if (copied) Icons.Default.Check else Icons.Default.ContentCopy,
                    contentDescription = if (copied) "Kopyalandı" else "Kopyala",
                    tint = if (copied) colors.green else colors.ink.copy(alpha = 0.5f),
                    modifier = Modifier.size(15.dp),
                )
            }
        }

        // Hairline separator
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(0.5.dp)
                .background(colors.line),
        )

        // Code Body
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 10.dp),
        ) {
            lines.forEachIndexed { index, line ->
                val isAdded = isDiff && line.startsWith("+") && !line.startsWith("+++")
                val isRemoved = isDiff && line.startsWith("-") && !line.startsWith("---")
                val rowBg = when {
                    isAdded -> colors.green.copy(alpha = 0.12f)
                    isRemoved -> colors.red.copy(alpha = 0.12f)
                    else -> Color.Transparent
                }

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(rowBg)
                        .padding(horizontal = 12.dp, vertical = 1.dp),
                ) {
                    Text(
                        text = "${index + 1}",
                        fontFamily = WiqoMono,
                        fontSize = 12.sp,
                        color = colors.ink3,
                        modifier = Modifier.width(28.dp),
                        textAlign = TextAlign.End,
                    )
                    Spacer(Modifier.width(12.dp))
                    Text(
                        text = line,
                        fontFamily = WiqoMono,
                        fontSize = 12.sp,
                        color = when {
                            isAdded -> colors.green
                            isRemoved -> colors.red
                            else -> colors.ink
                        },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}
