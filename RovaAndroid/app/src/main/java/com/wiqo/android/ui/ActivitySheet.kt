package com.wiqo.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccessTime
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.PendingActions
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.components.WiqoRow
import com.wiqo.android.ui.components.WiqoSettingsGroup
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans
import kotlinx.coroutines.launch

data class ActivityDisplayItem(
    val id: String,
    val title: String,
    val subtitle: String,
    val status: String,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ActivitySheet(
    onDismiss: () -> Unit,
    needsAttention: List<ActivityDisplayItem> = emptyList(),
    upcoming: List<ActivityDisplayItem> = emptyList(),
    recent: List<ActivityDisplayItem> = emptyList(),
) {
    val colors = WiqoDesign.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.canvas,
        shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 36.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = "Etkinlik",
                    fontFamily = WiqoSans,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.ink,
                )
                TextButton(
                    onClick = {
                        scope.launch { sheetState.hide() }.invokeOnCompletion { onDismiss() }
                    },
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

            if (needsAttention.isNotEmpty()) {
                WiqoSettingsGroup(title = "İlgi bekleyen") {
                    needsAttention.forEachIndexed { index, item ->
                        WiqoRow(
                            title = item.title,
                            icon = Icons.Default.PendingActions,
                            subtitle = item.subtitle,
                            showsDivider = index < needsAttention.lastIndex,
                        )
                    }
                }
            }

            if (upcoming.isNotEmpty()) {
                WiqoSettingsGroup(title = "Yaklaşan") {
                    upcoming.forEachIndexed { index, item ->
                        WiqoRow(
                            title = item.title,
                            icon = Icons.Default.AccessTime,
                            subtitle = item.subtitle,
                            showsDivider = index < upcoming.lastIndex,
                        )
                    }
                }
            }

            WiqoSettingsGroup(title = "Son etkinlik") {
                if (recent.isEmpty()) {
                    Text(
                        text = "Henüz son etkinlik yok",
                        fontFamily = WiqoSans,
                        fontSize = 13.sp,
                        color = colors.ink.copy(alpha = 0.5f),
                        modifier = Modifier.padding(16.dp),
                    )
                } else {
                    recent.forEachIndexed { index, item ->
                        WiqoRow(
                            title = item.title,
                            icon = Icons.Default.CheckCircle,
                            subtitle = item.subtitle,
                            showsDivider = index < recent.lastIndex,
                        )
                    }
                }
            }
        }
    }
}
