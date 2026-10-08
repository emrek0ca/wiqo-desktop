package com.wiqo.android.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.IconButton
import androidx.compose.material3.Button
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import kotlinx.coroutines.launch

private data class SettingsItem(val id: String, val title: String, val subtitle: String? = null)

private val settingsItems = listOf(
    SettingsItem("history", "Sohbet geçmişi", "Önceki konuşmaların"),
    SettingsItem("profile", "Hesap", "Profil ve oturum bilgileri"),
    SettingsItem("connected", "Bağlı hesaplar", "OAuth uygulamaları ve erişim düzeyleri"),
    SettingsItem("skills", "Beceriler", "Kişisel yönergelerin"),
    SettingsItem("agents", "Ajanlar", "Kişisel ajanlar ve çalışma durumu"),
    SettingsItem("agent-tasks", "Ajan görevleri", "Devam eden ve tamamlanan işler"),
    SettingsItem("memory", "Hafıza", "Wiqo’nun sakladığı notlar"),
    SettingsItem("memory-candidates", "Hafıza önerileri", "Gözden geçirilecek notlar"),
    SettingsItem("trust", "Güven izinleri", "Verilmiş PC ve işlem izinleri"),
    SettingsItem("tasks", "Görevler", "Yapılacak işler"),
    SettingsItem("goals", "Hedefler", "Uzun vadeli hedeflerin"),
    SettingsItem("automations", "Otomasyonlar", "Zamanlanmış ve tekrarlanan işler"),
    SettingsItem("subscription", "Wiqo Pro", "Plan ve kullanım"),
    SettingsItem("invites", "Davetler", "Davet kodların"),
)

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsScreen(
    preferences: com.wiqo.android.data.local.UserPreferencesStore,
    onNavigate: (DestinationData) -> Unit,
    onSignOut: () -> Unit,
    onBack: () -> Unit = {},
) {
    val themeMode by preferences.themeMode.collectAsState(initial = com.wiqo.android.data.local.ThemeMode.SYSTEM)
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var notificationsEnabled by remember { mutableStateOf(androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled()) }
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        notificationsEnabled = granted && androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled()
    }
    val notificationSettings = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        notificationsEnabled = androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled()
    }
    Scaffold(topBar = { TopAppBar(title = { Text("Ayarlar") }, navigationIcon = {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Geri") }
    }) }) { insets ->
        Column(Modifier.fillMaxSize().padding(insets).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            Spacer(Modifier.height(8.dp))
            Text("Görünüm", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(start = 4.dp, bottom = 8.dp))
            Row(Modifier.fillMaxWidth().padding(bottom = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(
                    com.wiqo.android.data.local.ThemeMode.SYSTEM to "Sistem",
                    com.wiqo.android.data.local.ThemeMode.LIGHT to "Açık",
                    com.wiqo.android.data.local.ThemeMode.DARK to "Koyu",
                ).forEach { (mode, label) ->
                    TextButton(onClick = { scope.launch { preferences.setThemeMode(mode) } }, modifier = Modifier.weight(1f)) {
                        Text(label, color = if (mode == themeMode) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            Card(
                modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp),
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                elevation = CardDefaults.cardElevation(defaultElevation = 1.dp),
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Bildirimler", style = MaterialTheme.typography.titleMedium)
                        Text(
                            if (notificationsEnabled) "Etkinlik ve onay bildirimleri açık" else "Görev ve onay güncellemelerini al",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Button(onClick = {
                        if (!notificationsEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                        } else {
                            val settingsIntent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                            runCatching { notificationSettings.launch(settingsIntent) }
                        }
                    }) { Text(if (notificationsEnabled) "Yönet" else "Aç") }
                }
            }
            settingsItems.forEach { item ->
                Card(
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp).clickable { onNavigate(DestinationData(item.id, null)) },
                    shape = RoundedCornerShape(16.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    elevation = CardDefaults.cardElevation(defaultElevation = 1.dp),
                ) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Column(Modifier.weight(1f)) {
                            Text(item.title, style = MaterialTheme.typography.titleMedium)
                            item.subtitle?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            TextButton(onClick = onSignOut, modifier = Modifier.align(Alignment.Start)) { Text("Çıkış yap", color = MaterialTheme.colorScheme.error) }
        }
    }
}
