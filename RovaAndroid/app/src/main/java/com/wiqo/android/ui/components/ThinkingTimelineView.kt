package com.wiqo.android.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoMono
import com.wiqo.android.ui.theme.WiqoSans

@Composable
fun ThinkingLiveView(
    label: String,
    modifier: Modifier = Modifier,
    elapsedSeconds: Int = 0,
) {
    val colors = WiqoDesign.colors

    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(14.dp),
            color = colors.ink.copy(alpha = 0.6f),
            strokeWidth = 2.dp,
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = label.ifBlank { "Bakıyorum…" },
            fontFamily = WiqoSans,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = colors.ink.copy(alpha = 0.7f),
        )
        Spacer(Modifier.weight(1f))
        if (elapsedSeconds >= 3) {
            Text(
                text = "${elapsedSeconds}s",
                fontFamily = WiqoMono,
                fontSize = 12.sp,
                color = colors.ink3,
            )
        }
    }
}

@Composable
fun ThinkingSummaryView(
    stepCount: Int,
    durationSeconds: Int,
    steps: List<String>,
    modifier: Modifier = Modifier,
) {
    val colors = WiqoDesign.colors
    var expanded by remember { mutableStateOf(false) }

    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = ripple(bounded = true),
                    onClick = { expanded = !expanded },
                )
                .padding(horizontal = 6.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = Icons.Default.CheckCircle,
                contentDescription = null,
                tint = colors.green,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = "$stepCount adımda tamamlandı · ${durationSeconds} sn",
                fontFamily = WiqoSans,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = colors.ink.copy(alpha = 0.6f),
            )
            Spacer(Modifier.width(4.dp))
            Icon(
                imageVector = Icons.Default.ArrowDropDown,
                contentDescription = null,
                tint = colors.ink3,
                modifier = Modifier
                    .size(16.dp)
                    .rotate(if (expanded) 0f else -90f),
            )
        }

        AnimatedVisibility(visible = expanded) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 20.dp, top = 4.dp, bottom = 4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                steps.forEach { step ->
                    Text(
                        text = "• $step",
                        fontFamily = WiqoSans,
                        fontSize = 12.sp,
                        color = colors.ink.copy(alpha = 0.6f),
                    )
                }
            }
        }
    }
}
