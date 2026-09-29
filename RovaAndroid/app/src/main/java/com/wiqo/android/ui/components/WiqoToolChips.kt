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
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Construction
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans

data class WiqoToolItem(
    val id: String,
    val label: String,
    val icon: ImageVector = Icons.Default.Construction,
    val chip: String? = null,
    val status: String? = null,
    val details: List<String> = emptyList(),
)

@Composable
fun WiqoToolChips(
    rows: List<WiqoToolItem>,
    modifier: Modifier = Modifier,
    summary: String? = null,
) {
    val colors = WiqoDesign.colors
    var isOpen by remember { mutableStateOf(true) }
    var expandedIds by remember { mutableStateOf(setOf<String>()) }

    Column(modifier = modifier.fillMaxWidth()) {
        if (rows.size > 1 && summary != null) {
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = ripple(bounded = true),
                        onClick = { isOpen = !isOpen },
                    )
                    .padding(horizontal = 6.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Default.ArrowDropDown,
                    contentDescription = null,
                    tint = colors.ink.copy(alpha = 0.6f),
                    modifier = Modifier
                        .size(16.dp)
                        .rotate(if (isOpen) 0f else -90f),
                )
                Spacer(Modifier.width(4.dp))
                Text(
                    text = summary,
                    fontFamily = WiqoSans,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = colors.ink.copy(alpha = 0.6f),
                )
            }
        }

        AnimatedVisibility(visible = isOpen || (rows.size <= 1 && summary == null)) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                rows.forEach { row ->
                    val isExpanded = expandedIds.contains(row.id)
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .clickable(
                                enabled = row.details.isNotEmpty(),
                                interactionSource = remember { MutableInteractionSource() },
                                indication = ripple(bounded = true),
                                onClick = {
                                    expandedIds = if (isExpanded) expandedIds - row.id else expandedIds + row.id
                                },
                            )
                            .padding(vertical = 2.dp),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                imageVector = row.icon,
                                contentDescription = null,
                                tint = colors.ink.copy(alpha = 0.6f),
                                modifier = Modifier.size(14.dp),
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = row.label,
                                fontFamily = WiqoSans,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium,
                                color = colors.ink,
                            )
                            if (row.chip != null) {
                                Spacer(Modifier.width(6.dp))
                                Box(
                                    modifier = Modifier
                                        .background(colors.inset, RoundedCornerShape(4.dp))
                                        .padding(horizontal = 6.dp, vertical = 2.dp),
                                ) {
                                    Text(
                                        text = row.chip,
                                        fontFamily = WiqoSans,
                                        fontSize = 11.sp,
                                        color = colors.ink.copy(alpha = 0.7f),
                                    )
                                }
                            }
                            Spacer(Modifier.weight(1f))
                            if (row.details.isNotEmpty()) {
                                Icon(
                                    imageVector = Icons.Default.ChevronRight,
                                    contentDescription = null,
                                    tint = colors.ink3,
                                    modifier = Modifier
                                        .size(14.dp)
                                        .rotate(if (isExpanded) 90f else 0f),
                                )
                            }
                        }

                        if (isExpanded && row.details.isNotEmpty()) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(start = 22.dp, top = 4.dp),
                                verticalArrangement = Arrangement.spacedBy(2.dp),
                            ) {
                                row.details.forEach { detail ->
                                    Text(
                                        text = detail,
                                        fontFamily = WiqoSans,
                                        fontSize = 12.sp,
                                        color = colors.ink.copy(alpha = 0.6f),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
