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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeDown
import androidx.compose.material.icons.automirrored.filled.VolumeMute
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.BrightnessMedium
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Nightlight
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.components.RovaActionTile
import com.wiqo.android.ui.components.WiqoCard
import com.wiqo.android.ui.components.WiqoPillButton
import com.wiqo.android.ui.components.WiqoPillKind
import com.wiqo.android.ui.components.WiqoRow
import com.wiqo.android.ui.components.WiqoSettingsGroup
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PCSettingsSheet(
    onDismiss: () -> Unit,
    isPaired: Boolean,
    isConnected: Boolean,
    deviceName: String = "PC",
    onOpenPairing: () -> Unit,
    onForgetDevice: () -> Unit,
    onLockPC: () -> Unit = {},
    onSleepPC: () -> Unit = {},
    onMutePC: () -> Unit = {},
    onDisplaySleepPC: () -> Unit = {},
    onVolumeChange: (Float) -> Unit = {},
    onBrightnessChange: (Float) -> Unit = {},
    initialVolume: Float = 0.5f,
    initialBrightness: Float = 0.8f,
) {
    val colors = WiqoDesign.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    var showForgetConfirmation by remember { mutableStateOf(false) }
    var volume by remember { mutableFloatStateOf(initialVolume) }
    var brightness by remember { mutableFloatStateOf(initialBrightness) }

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
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            // Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = "PC Ayarları",
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

            if (!isPaired) {
                // Not paired card
                WiqoCard {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = Icons.Default.Computer,
                            contentDescription = null,
                            tint = colors.ink,
                            modifier = Modifier.size(28.dp),
                        )
                        Spacer(Modifier.width(14.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = "PC'ye bağlan",
                                fontFamily = WiqoSans,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = colors.ink,
                            )
                            Spacer(Modifier.height(2.dp))
                            Text(
                                text = "PC'ndeki Wiqo uygulamasındaki QR kodu tara.",
                                fontFamily = WiqoSans,
                                fontSize = 12.sp,
                                color = colors.ink.copy(alpha = 0.6f),
                            )
                        }
                        WiqoPillButton(
                            text = "Bağla",
                            kind = WiqoPillKind.Accent,
                            onClick = onOpenPairing,
                            height = 36.dp,
                        )
                    }
                }
            } else {
                // Status card
                WiqoCard {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = Icons.Default.Computer,
                            contentDescription = null,
                            tint = if (isConnected) colors.signal else colors.ink.copy(alpha = 0.5f),
                            modifier = Modifier.size(28.dp),
                        )
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = deviceName,
                                fontFamily = WiqoSans,
                                fontSize = 16.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = colors.ink,
                            )
                            Text(
                                text = if (isConnected) "Bağlı" else "Bağlantı kesildi",
                                fontFamily = WiqoSans,
                                fontSize = 12.sp,
                                color = if (isConnected) colors.signal else colors.ink.copy(alpha = 0.5f),
                            )
                        }
                    }
                }

                // Quick Action Tiles
                Text(
                    text = "Hızlı İşlemler",
                    fontFamily = WiqoSans,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = colors.ink.copy(alpha = 0.6f),
                    modifier = Modifier.padding(horizontal = 4.dp),
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    RovaActionTile(title = "Kilitle", icon = Icons.Default.Lock, onClick = onLockPC)
                    RovaActionTile(title = "Uyut", icon = Icons.Default.Nightlight, onClick = onSleepPC)
                    RovaActionTile(title = "Sessiz", icon = Icons.AutoMirrored.Filled.VolumeMute, onClick = onMutePC)
                    RovaActionTile(title = "Ekran", icon = Icons.Default.PowerSettingsNew, onClick = onDisplaySleepPC)
                }

                // Media sliders card
                WiqoCard {
                    Text(
                        text = "Medya ve Ekran",
                        fontFamily = WiqoSans,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.ink,
                    )
                    Spacer(Modifier.height(8.dp))

                    // Volume
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.AutoMirrored.Filled.VolumeDown, contentDescription = null, tint = colors.ink.copy(alpha = 0.5f), modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Slider(
                            value = volume,
                            onValueChange = {
                                volume = it
                                onVolumeChange(it)
                            },
                            modifier = Modifier.weight(1f),
                            colors = SliderDefaults.colors(thumbColor = colors.ink, activeTrackColor = colors.ink),
                        )
                        Spacer(Modifier.width(8.dp))
                        Icon(Icons.AutoMirrored.Filled.VolumeUp, contentDescription = null, tint = colors.ink.copy(alpha = 0.5f), modifier = Modifier.size(18.dp))
                    }

                    // Brightness
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.BrightnessMedium, contentDescription = null, tint = colors.ink.copy(alpha = 0.5f), modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Slider(
                            value = brightness,
                            onValueChange = {
                                brightness = it
                                onBrightnessChange(it)
                            },
                            modifier = Modifier.weight(1f),
                            colors = SliderDefaults.colors(thumbColor = colors.ink, activeTrackColor = colors.ink),
                        )
                    }
                }

                // Danger section
                WiqoSettingsGroup {
                    WiqoRow(
                        title = "PC'yi unut",
                        icon = Icons.Default.Delete,
                        isDestructive = true,
                        showsDivider = false,
                        onClick = { showForgetConfirmation = true },
                        trailing = {},
                    )
                }
            }
        }

        if (showForgetConfirmation) {
            AlertDialog(
                onDismissRequest = { showForgetConfirmation = false },
                title = { Text("PC'yi unutmak istediğine emin misin?", fontFamily = WiqoSans, fontWeight = FontWeight.SemiBold) },
                text = { Text("Bu PC ile olan bağlantı ve güven izinleri silinecek.", fontFamily = WiqoSans) },
                confirmButton = {
                    TextButton(
                        onClick = {
                            showForgetConfirmation = false
                            onForgetDevice()
                            onDismiss()
                        },
                    ) {
                        Text("PC'yi unut", color = colors.red, fontFamily = WiqoSans, fontWeight = FontWeight.Medium)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showForgetConfirmation = false }) {
                        Text("Vazgeç", color = colors.ink, fontFamily = WiqoSans)
                    }
                },
            )
        }
    }
}
