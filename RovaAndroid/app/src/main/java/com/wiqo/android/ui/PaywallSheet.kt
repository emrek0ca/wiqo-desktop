package com.wiqo.android.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.components.WiqoActionButton
import com.wiqo.android.ui.components.WiqoCard
import com.wiqo.android.ui.components.WiqoPillButton
import com.wiqo.android.ui.components.WiqoPillKind
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PaywallSheet(
    onDismiss: () -> Unit,
    onSubscribePro: () -> Unit,
    onRestore: () -> Unit = {},
    currentTier: String = "free",
    proPrice: String = "₺499,99/ay",
    isPurchasing: Boolean = false,
) {
    val colors = WiqoDesign.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

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
                    text = "Planlar",
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

            // Title banner
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = "Wiqo'yu yükselt",
                    fontFamily = WiqoSans,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Bold,
                    color = colors.ink,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "Daha fazla mesaj, görsel ve PC bağlantısı için bir plan seç.",
                    fontFamily = WiqoSans,
                    fontSize = 13.sp,
                    color = colors.ink.copy(alpha = 0.6f),
                    textAlign = TextAlign.Center,
                )
            }

            // Free Card
            WiqoCard {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "Free",
                        fontFamily = WiqoSans,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Bold,
                        color = colors.ink,
                    )
                    Text(
                        text = "Ücretsiz",
                        fontFamily = WiqoSans,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.ink.copy(alpha = 0.6f),
                    )
                }
                Spacer(Modifier.height(8.dp))
                listOf("Günde 10 mesaj", "Günde 1 görsel", "PC bağlantısı yok").forEach { feature ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Check, contentDescription = null, tint = colors.ink.copy(alpha = 0.4f), modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(text = feature, fontFamily = WiqoSans, fontSize = 13.sp, color = colors.ink.copy(alpha = 0.7f))
                    }
                }
                if (currentTier.lowercase() == "free") {
                    Spacer(Modifier.height(10.dp))
                    Text(
                        text = "Mevcut planın",
                        fontFamily = WiqoSans,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.ink.copy(alpha = 0.5f),
                    )
                }
            }

            // Pro Card
            WiqoCard {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "Pro",
                        fontFamily = WiqoSans,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Bold,
                        color = colors.ink,
                    )
                    Text(
                        text = proPrice,
                        fontFamily = WiqoSans,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.ink,
                    )
                }
                Spacer(Modifier.height(8.dp))
                listOf("Günde 100 mesaj", "Günde 10 görsel", "PC bağlantısı").forEach { feature ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Check, contentDescription = null, tint = colors.green, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(text = feature, fontFamily = WiqoSans, fontSize = 13.sp, color = colors.ink)
                    }
                }
                Spacer(Modifier.height(12.dp))
                if (currentTier.lowercase() == "pro") {
                    Text(
                        text = "Mevcut planın",
                        fontFamily = WiqoSans,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = colors.green,
                    )
                } else {
                    WiqoActionButton(
                        title = "Pro'ya geç",
                        isLoading = isPurchasing,
                        onClick = onSubscribePro,
                    )
                }
            }

            // Restore button
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                TextButton(onClick = onRestore) {
                    Text(
                        text = "Satın alımları geri yükle",
                        fontFamily = WiqoSans,
                        fontSize = 13.sp,
                        color = colors.ink.copy(alpha = 0.6f),
                    )
                }
            }

            // Legal footer
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.Center,
            ) {
                TextButton(
                    onClick = {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://wiqo.app/terms")))
                    },
                ) {
                    Text("Kullanım Koşulları", fontFamily = WiqoSans, fontSize = 11.sp, color = colors.ink3)
                }
                Text("•", color = colors.ink3, modifier = Modifier.align(Alignment.CenterVertically))
                TextButton(
                    onClick = {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://wiqo.app/privacy")))
                    },
                ) {
                    Text("Gizlilik Politikası", fontFamily = WiqoSans, fontSize = 11.sp, color = colors.ink3)
                }
            }
        }
    }
}
