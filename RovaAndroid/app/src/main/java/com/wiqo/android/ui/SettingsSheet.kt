package com.wiqo.android.ui

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.TrackChanges
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsSheet(
    onDismiss: () -> Unit,
    onOpenPC: () -> Unit,
    onOpenActivity: () -> Unit,
    onSignOut: () -> Unit = {},
    onOpenTasks: () -> Unit = {},
    onOpenMemory: () -> Unit = {},
    onOpenGoals: () -> Unit = {},
    onOpenAccount: () -> Unit = {},
    onOpenAdvanced: () -> Unit = {},
    isPaired: Boolean = false,
    deviceName: String = "PC",
    userName: String = "Osman Emre",
) {
    val colors = WiqoDesign.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.surface,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 36.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            // Header: Centered title and right "Kapat" pill button matching screenshot
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 12.dp),
            ) {
                Text(
                    text = "Ayarlar",
                    fontFamily = WiqoSans,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.ink,
                    modifier = Modifier.align(Alignment.Center),
                )

                // "Kapat" pill button
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterEnd)
                        .clip(CircleShape)
                        .background(colors.canvas)
                        .border(1.dp, colors.line, CircleShape)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = {
                                scope.launch { sheetState.hide() }.invokeOnCompletion { onDismiss() }
                            },
                        )
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "Kapat",
                        fontFamily = WiqoSans,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.ink,
                    )
                }
            }

            Spacer(Modifier.height(14.dp))

            // Main Settings Card matching screenshot exactly
            val cardShape = RoundedCornerShape(16.dp)
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(cardShape)
                    .background(colors.canvas)
                    .border(1.dp, colors.line.copy(alpha = 0.6f), cardShape),
            ) {
                SettingsNavigationRow(
                    title = "PC",
                    icon = Icons.Outlined.Laptop,
                    value = if (isPaired) deviceName else "Bağla",
                    showsDivider = true,
                    onClick = onOpenPC,
                )

                SettingsNavigationRow(
                    title = "Görevler",
                    icon = Icons.Outlined.Checklist,
                    value = "İncele",
                    showsDivider = true,
                    onClick = onOpenTasks,
                )

                SettingsNavigationRow(
                    title = "Etkinlik",
                    icon = Icons.Outlined.History,
                    value = "Yapılanlar ve bekleyenler",
                    showsDivider = true,
                    onClick = onOpenActivity,
                )

                SettingsNavigationRow(
                    title = "Hafıza",
                    icon = Icons.Outlined.Psychology,
                    value = "Gör ve yönet",
                    showsDivider = true,
                    onClick = onOpenMemory,
                )

                SettingsNavigationRow(
                    title = "Hedefler",
                    icon = Icons.Outlined.TrackChanges,
                    value = "İlerlemeyi gör",
                    showsDivider = true,
                    onClick = onOpenGoals,
                )

                SettingsNavigationRow(
                    title = "Hesap",
                    icon = Icons.Outlined.AccountCircle,
                    value = userName.ifBlank { "Osman Emre" },
                    showsDivider = true,
                    onClick = onOpenAccount,
                )

                SettingsNavigationRow(
                    title = "Gelişmiş",
                    icon = Icons.Outlined.Tune,
                    value = "Yasal ve destek",
                    showsDivider = false,
                    onClick = onOpenAdvanced,
                )
            }
        }
    }
}

@Composable
private fun SettingsNavigationRow(
    title: String,
    icon: ImageVector,
    value: String,
    showsDivider: Boolean,
    onClick: () -> Unit,
) {
    val colors = WiqoDesign.colors
    val interactionSource = remember { MutableInteractionSource() }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            ),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = colors.ink.copy(alpha = 0.6f),
                modifier = Modifier.size(20.dp),
            )

            Spacer(Modifier.width(12.dp))

            Text(
                text = title,
                fontFamily = WiqoSans,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                color = colors.ink,
            )

            Spacer(Modifier.weight(1f))

            Text(
                text = value,
                fontFamily = WiqoSans,
                fontSize = 14.sp,
                color = colors.ink3,
                maxLines = 1,
            )

            Spacer(Modifier.width(6.dp))

            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.ink.copy(alpha = 0.25f),
                modifier = Modifier.size(16.dp),
            )
        }

        if (showsDivider) {
            HorizontalDivider(
                modifier = Modifier.padding(start = 46.dp),
                thickness = 0.5.dp,
                color = colors.separator,
            )
        }
    }
}
