package com.wiqo.android.ui

import androidx.compose.foundation.background
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
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.components.WiqoActionButton
import com.wiqo.android.ui.components.WiqoField
import com.wiqo.android.ui.components.WiqoPillButton
import com.wiqo.android.ui.components.WiqoPillKind
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairingSheet(
    onDismiss: () -> Unit,
    onStartQrScan: () -> Unit,
    onPairWithCode: (String) -> Unit,
    isPairing: Boolean = false,
    errorMessage: String? = null,
    hasCelebrated: Boolean = false,
) {
    val colors = WiqoDesign.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var manualCode by remember { mutableStateOf("") }

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
            // Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = "Wiqo",
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

            Spacer(Modifier.height(8.dp))

            Icon(
                imageVector = Icons.Default.Devices,
                contentDescription = null,
                tint = colors.ink,
                modifier = Modifier.size(54.dp),
            )

            Text(
                text = "PC'ye bağlan",
                fontFamily = WiqoSans,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                color = colors.ink,
            )

            Text(
                text = "Wiqo PC'de gösterilen QR kodu tara veya eşleşme kodunu gir.",
                fontFamily = WiqoSans,
                fontSize = 14.sp,
                color = colors.ink.copy(alpha = 0.6f),
                textAlign = TextAlign.Center,
            )

            WiqoActionButton(
                title = "QR tara",
                onClick = onStartQrScan,
            )

            Text(
                text = "veya kod ile bağlan",
                fontFamily = WiqoSans,
                fontSize = 12.sp,
                color = colors.ink3,
            )

            WiqoField {
                BasicTextField(
                    value = manualCode,
                    onValueChange = { manualCode = it.trim() },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    cursorBrush = SolidColor(colors.ink),
                    textStyle = androidx.compose.ui.text.TextStyle(
                        fontFamily = WiqoSans,
                        fontSize = 15.sp,
                        color = colors.ink,
                    ),
                    decorationBox = { inner ->
                        if (manualCode.isEmpty()) Text("Eşleşme kodu", fontFamily = WiqoSans, fontSize = 15.sp, color = colors.ink3)
                        inner()
                    },
                )
            }

            if (manualCode.isNotBlank()) {
                WiqoPillButton(
                    text = "Kodu onayla",
                    kind = WiqoPillKind.Secondary,
                    isLoading = isPairing,
                    onClick = { onPairWithCode(manualCode) },
                )
            }

            if (isPairing) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), color = colors.ink, strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Text(text = "PC'yi bağlıyorum…", fontFamily = WiqoSans, fontSize = 14.sp, color = colors.ink.copy(alpha = 0.7f))
                }
            }

            if (errorMessage != null) {
                Text(
                    text = errorMessage,
                    fontFamily = WiqoSans,
                    fontSize = 13.sp,
                    color = colors.red,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}
