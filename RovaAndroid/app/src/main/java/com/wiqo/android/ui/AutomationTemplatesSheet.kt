package com.wiqo.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Launch
import androidx.compose.material.icons.filled.BatteryAlert
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Nightlight
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.ui.components.WiqoRow
import com.wiqo.android.ui.components.WiqoSettingsGroup
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans
import kotlinx.coroutines.launch

private data class AutomationTemplate(
    val title: String,
    val detail: String,
    val icon: ImageVector,
    val prompt: String,
)

private val templates = listOf(
    AutomationTemplate(
        "Sabah brifingi",
        "Her sabah hava durumu ve gündemi özetler",
        Icons.Default.WbSunny,
        "Her sabah 08:00'de bana hava durumunu ve takvimimdeki bugünkü etkinlikleri özetleyen bir otomasyon oluştur.",
    ),
    AutomationTemplate(
        "Pil uyarısı",
        "PC pili azalınca haber verir",
        Icons.Default.BatteryAlert,
        "PC'min pili %20'nin altına düştüğünde bana haber veren bir otomasyon oluştur.",
    ),
    AutomationTemplate(
        "Hafta sonu hatırlatıcı özeti",
        "Cuma akşamı bekleyen hatırlatıcıları listeler",
        Icons.Default.Checklist,
        "Her Cuma 18:00'de tamamlanmamış hatırlatıcılarımı özetleyen bir otomasyon oluştur.",
    ),
    AutomationTemplate(
        "Odak modu",
        "Belirlediğin saatte Rahatsız Etmeyi açar",
        Icons.Default.Nightlight,
        "Her gün 09:00'da Rahatsız Etme'yi açan, 18:00'de kapatan bir otomasyon oluştur.",
    ),
    AutomationTemplate(
        "Haftalık takvim özeti",
        "Pazartesi sabahı haftanın programını çıkarır",
        Icons.Default.CalendarMonth,
        "Her Pazartesi 08:30'da o haftaki takvim etkinliklerimi özetleyen bir otomasyon oluştur.",
    ),
    AutomationTemplate(
        "İndirilenler temizliği",
        "Her hafta eski dosyaları ayıklar",
        Icons.Default.DeleteSweep,
        "Her Pazar 20:00'de İndirilenler klasöründeki 30 günden eski dosyaları listeleyip benden onay isteyen bir otomasyon oluştur.",
    ),
    AutomationTemplate(
        "Gece kilidi",
        "Belirlediğin saatte PC'yi otomatik kilitler",
        Icons.Default.Lock,
        "Her gece 00:30'da PC'mi otomatik kilitleyen bir otomasyon oluştur.",
    ),
    AutomationTemplate(
        "Akşam özet e-postası",
        "Günün özetini akşam bana gönderir",
        Icons.Default.Email,
        "Her gün 19:00'da o günkü yaptıklarımın kısa bir özetini bana ileten bir otomasyon oluştur.",
    ),
    AutomationTemplate(
        "Pano temizliği",
        "Panoyu belirli aralıklarla temizler",
        Icons.Default.ContentPaste,
        "Her gün 22:00'de PC'min panosunu (clipboard) temizleyen bir otomasyon oluştur.",
    ),
    AutomationTemplate(
        "Ayın başı hatırlatıcı",
        "Her ayın ilk günü bir hatırlatma gönderir",
        Icons.Default.NotificationsActive,
        "Her ayın 1'inde saat 09:00'da o ay için bütçe/faturalarımı gözden geçirmemi hatırlatan bir otomasyon oluştur.",
    ),
    AutomationTemplate(
        "Uygulama açılışı",
        "Gün başında sık kullandığın uygulamaları açar",
        Icons.AutoMirrored.Filled.Launch,
        "Her hafta içi 09:00'da mail ve takvim uygulamalarımı PC'de otomatik açan bir otomasyon oluştur.",
    ),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AutomationTemplatesSheet(
    onDismiss: () -> Unit,
    onSelectPrompt: (String) -> Unit,
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
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            // Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = "Otomasyon Şablonları",
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

            WiqoSettingsGroup(title = "Hazır Şablonlar") {
                templates.forEachIndexed { index, template ->
                    WiqoRow(
                        title = template.title,
                        icon = template.icon,
                        subtitle = template.detail,
                        showsDivider = index < templates.lastIndex,
                        onClick = {
                            onSelectPrompt(template.prompt)
                            scope.launch { sheetState.hide() }.invokeOnCompletion { onDismiss() }
                        },
                    )
                }
            }
        }
    }
}
