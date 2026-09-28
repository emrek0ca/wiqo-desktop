package com.wiqo.android.ui.components

import androidx.compose.animation.AnimatedVisibility
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.Security
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans

data class WiqoApprovalField(val id: String, val label: String, val value: String)

@Composable
fun WiqoApprovalCard(
    title: String,
    summary: String,
    onApprove: () -> Unit,
    onDecline: () -> Unit,
    modifier: Modifier = Modifier,
    fields: List<WiqoApprovalField> = emptyList(),
    isDestructive: Boolean = false,
    isProcessing: Boolean = false,
    approveTitle: String = "Onayla",
    declineTitle: String = "Reddet",
) {
    val colors = WiqoDesign.colors
    var showsFields by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(WiqoDesign.CardRadius)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .shadow(6.dp, shape, ambientColor = Color.Black.copy(alpha = 0.05f))
            .clip(shape)
            .background(colors.surface, shape)
            .border(0.5.dp, colors.line, shape),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(
                    imageVector = if (isDestructive) Icons.Default.Security else Icons.Default.PanTool,
                    contentDescription = null,
                    tint = colors.orange,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = title,
                        fontFamily = WiqoSans,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.ink.copy(alpha = 0.6f),
                    )
                    Spacer(Modifier.height(3.dp))
                    Text(
                        text = summary,
                        fontFamily = WiqoSans,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.ink,
                    )
                }
            }

            if (fields.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                Row(
                    modifier = Modifier
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = { showsFields = !showsFields },
                        )
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Default.ChevronRight,
                        contentDescription = null,
                        tint = colors.ink.copy(alpha = 0.6f),
                        modifier = Modifier
                            .size(14.dp)
                            .rotate(if (showsFields) 90f else 0f),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = "Ayrıntılar",
                        fontFamily = WiqoSans,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.ink.copy(alpha = 0.6f),
                    )
                }

                AnimatedVisibility(visible = showsFields) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 6.dp)
                            .background(colors.inset, RoundedCornerShape(WiqoDesign.ControlRadius))
                            .padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        fields.forEach { field ->
                            Column {
                                Text(
                                    text = field.label,
                                    fontFamily = WiqoSans,
                                    fontSize = 11.sp,
                                    color = colors.ink3,
                                )
                                Text(
                                    text = field.value,
                                    fontFamily = WiqoSans,
                                    fontSize = 12.sp,
                                    color = colors.ink,
                                )
                            }
                        }
                    }
                }
            }
        }

        // Hairline separator
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(0.5.dp)
                .background(colors.line),
        )

        // Footer buttons
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
        ) {
            WiqoPillButton(
                text = declineTitle,
                onClick = onDecline,
                kind = WiqoPillKind.Secondary,
                enabled = !isProcessing,
                height = 36.dp,
            )
            WiqoPillButton(
                text = approveTitle,
                onClick = onApprove,
                kind = WiqoPillKind.Accent,
                isLoading = isProcessing,
                height = 36.dp,
            )
        }
    }
}
