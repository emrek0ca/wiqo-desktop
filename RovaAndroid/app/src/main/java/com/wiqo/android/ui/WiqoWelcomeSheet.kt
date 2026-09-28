package com.wiqo.android.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.components.WiqoActionButton
import com.wiqo.android.ui.components.WiqoPillButton
import com.wiqo.android.ui.components.WiqoPillKind
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WiqoWelcomeSheet(
    onDismiss: () -> Unit,
    onConnect: () -> Unit,
) {
    val colors = WiqoDesign.colors
    val context = LocalContext.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.canvas,
        shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 36.dp)
                .verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Icon(
                imageVector = Icons.Default.Devices,
                contentDescription = null,
                tint = colors.ink,
                modifier = Modifier.size(48.dp),
            )

            Text(
                text = "PC'ni bağla",
                fontFamily = WiqoSans,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                color = colors.ink,
            )

            Text(
                text = "PC'nde Wiqo'yu aç, ekrandaki QR kodu tara ve ilk komutunu ver.",
                fontFamily = WiqoSans,
                fontSize = 15.sp,
                color = colors.ink.copy(alpha = 0.6f),
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(8.dp))

            WiqoActionButton(
                title = "PC uygulamasını indir",
                kind = WiqoPillKind.Accent,
                onClick = {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://wiqo.app/download")))
                },
            )

            WiqoActionButton(
                title = "QR kodu tara",
                kind = WiqoPillKind.Secondary,
                onClick = onConnect,
            )

            WiqoPillButton(
                text = "Şimdi değil",
                kind = WiqoPillKind.Ghost,
                onClick = onDismiss,
            )
        }
    }
}
