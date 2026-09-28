package com.wiqo.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.wiqo.android.AppContainer
import kotlinx.coroutines.launch
import android.content.Intent
import android.net.Uri
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun RemotePage(
    container: AppContainer,
    destination: DestinationData,
    title: String,
    onBack: (() -> Unit)? = null,
    onPair: (() -> Unit)? = null,
    onSelect: ((String) -> Unit)? = null,
) {
    val path = endpointFor(destination)
    val vm: RemotePageViewModel = viewModel(key = "remote-$path-${destination.path.orEmpty()}", factory = RemotePageViewModel.Factory(container, path))
    val state by vm.state.collectAsStateWithLifecycle()
    var pendingAction by remember(path) { mutableStateOf<RemoteAction?>(null) }
    var showSkillEditor by remember(path) { mutableStateOf(false) }
    var skillName by remember(path) { mutableStateOf("") }
    var skillPrompt by remember(path) { mutableStateOf("") }
    val context = androidx.compose.ui.platform.LocalContext.current
    var launchError by remember(path) { mutableStateOf<String?>(null) }
    androidx.compose.runtime.LaunchedEffect(state.openUrl) {
        val url = state.openUrl ?: return@LaunchedEffect
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
            .onFailure { launchError = "Tarayıcı açılamadı. Cihazında bir tarayıcı bulunduğundan emin ol." }
        vm.consumeOpenUrl()
    }
    Scaffold(topBar = {
        TopAppBar(
            title = { Text(title) },
            navigationIcon = { if (onBack != null) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Geri") } },
            actions = {
                if (destination.id == "skills") TextButton(onClick = { showSkillEditor = true }) { Text("Yeni beceri") }
                if (onPair != null) IconButton(onClick = onPair) { Icon(Icons.Filled.QrCodeScanner, "PC eşleştir") }
                IconButton(onClick = vm::refresh) { Icon(Icons.Filled.Refresh, "Yenile") }
            },
        )
    }) { insets ->
        Column(Modifier.fillMaxSize().padding(insets)) {
            destination.notice?.let { Text(it, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), color = MaterialTheme.colorScheme.primary) }
            if (destination.id == "connected") {
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { vm.startOAuth("google") }, enabled = state.busyAction == null) { Text("Google bağla") }
                    Button(onClick = { vm.startOAuth("notion") }, enabled = state.busyAction == null) { Text("Notion bağla") }
                }
            }
            launchError?.let { Text(it, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), color = MaterialTheme.colorScheme.error) }
            state.notice?.let { Text(it, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), color = MaterialTheme.colorScheme.primary) }
            state.busyAction?.let { androidx.compose.material3.LinearProgressIndicator(Modifier.fillMaxWidth()) }
            state.commandResult?.let { result ->
                Card(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), shape = RoundedCornerShape(16.dp)) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("PC durumu", style = MaterialTheme.typography.titleMedium)
                        result.displayDetails().forEach { (key, value) ->
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(key.toUiLabel(), color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(value)
                            }
                        }
                    }
                }
            }
            when {
                state.loading && state.data == null -> Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) { CircularProgressIndicator() }
                state.error != null -> Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    Text(state.error ?: "İstek tamamlanamadı.", color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = vm::refresh) { Text("Tekrar dene") }
                }
                else -> {
                    val items = state.data?.visibleItems().orEmpty()
                    if (items.isEmpty()) {
                        Column(Modifier.fillMaxSize().padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                            Text(emptyMessage(destination.id), style = MaterialTheme.typography.titleMedium)
                            Spacer(Modifier.height(8.dp))
                            Text("Yeni bilgiler geldiğinde bu ekran güncellenecek.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    } else LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        if (state.loading) item { LinearProgress() }
                        items(items) { entry ->
                            val itemId = entry.itemIdentifier()
                            Card(
                                modifier = Modifier.fillMaxWidth().then(
                                    if (onSelect != null && itemId != null) Modifier.clickable { onSelect(itemId) } else Modifier,
                                ),
                                shape = RoundedCornerShape(16.dp),
                                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                                elevation = CardDefaults.cardElevation(defaultElevation = 1.dp),
                            ) {
                                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Text(entry.displayTitle(), style = MaterialTheme.typography.titleMedium)
                                    entry.displayDetails().forEach { (key, value) ->
                                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                            Text(key.toUiLabel(), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                                            Text(value, style = MaterialTheme.typography.bodyMedium, maxLines = 2)
                                        }
                                    }
                                    val entryActions = remoteActions(destination.id, entry)
                                    if (entryActions.isNotEmpty()) {
                                        Column {
                                            entryActions.forEach { action ->
                                                TextButton(
                                                    onClick = {
                                                        if (action.needsConfirmation) pendingAction = action else vm.perform(action)
                                                    },
                                                    enabled = state.busyAction == null,
                                                ) { Text(action.label) }
                                            }
                                        }
                                    }
                                    val confirmation = entry.confirmation()
                                    val confirmationId = (confirmation?.get("id") as? JsonPrimitive)?.content
                                    if (destination.id == "activity" && confirmation != null && confirmationId != null) {
                                        val details = confirmation["details"] as? JsonObject ?: JsonObject(emptyMap())
                                        details.entries
                                            .filterNot { (key, _) -> key.startsWith("wiqo") }
                                            .forEach { (key, value) ->
                                                val text = (value as? JsonPrimitive)?.content ?: return@forEach
                                                if (text.isNotBlank()) {
                                                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                                        Text(key.toUiLabel(), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                                                        Text(text, style = MaterialTheme.typography.bodySmall, maxLines = 3)
                                                    }
                                                }
                                            }
                                        Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                                            TextButton(
                                                onClick = {
                                                    val body = container.api.backendConfirmationBody(confirmationId, false, details)
                                                    vm.perform(RemoteAction("Reddediliyor", "copilot/confirm", "POST", body, successMessage = "İşlem reddedildi."))
                                                },
                                                enabled = state.busyAction == null,
                                            ) { Text("Reddet") }
                                            TextButton(
                                                onClick = {
                                                    runCatching { container.api.backendConfirmationBody(confirmationId, true, details) }
                                                        .onSuccess { body -> vm.perform(RemoteAction("Onaylanıyor", "copilot/confirm", "POST", body, successMessage = "İşlem onaylandı.")) }
                                                        .onFailure { error -> launchError = error.message ?: "Onay hazırlanamadı." }
                                                },
                                                enabled = state.busyAction == null,
                                            ) { Text("Onayla") }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    pendingAction?.let { action ->
        AlertDialog(
            onDismissRequest = { pendingAction = null },
            title = { Text(action.label) },
            text = { Text("Bu işlem Wiqo hesabındaki kayıtları veya bağlı bilgisayar görevini etkiler. Devam edilsin mi?") },
            confirmButton = {
                TextButton(onClick = { pendingAction = null; vm.perform(action) }) { Text("Devam et") }
            },
            dismissButton = { TextButton(onClick = { pendingAction = null }) { Text("Vazgeç") } },
        )
    }
    if (showSkillEditor) {
        AlertDialog(
            onDismissRequest = { showSkillEditor = false },
            title = { Text("Beceri oluştur") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(value = skillName, onValueChange = { skillName = it.take(80) }, label = { Text("Beceri adı") }, singleLine = true)
                    OutlinedTextField(value = skillPrompt, onValueChange = { skillPrompt = it.take(6_000) }, label = { Text("Yönerge") }, minLines = 4, maxLines = 8)
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val body = buildJsonObject {
                            put("name", skillName.trim())
                            put("prompt", skillPrompt.trim())
                        }
                        showSkillEditor = false
                        vm.perform(RemoteAction("Beceri kaydediliyor", "skills", "POST", body, successMessage = "Beceri oluşturuldu."))
                    },
                    enabled = skillName.isNotBlank() && skillPrompt.isNotBlank() && state.busyAction == null,
                ) { Text("Kaydet") }
            },
            dismissButton = { TextButton(onClick = { showSkillEditor = false }) { Text("Vazgeç") } },
        )
    }
}

@Composable
private fun LinearProgress() { androidx.compose.material3.LinearProgressIndicator(Modifier.fillMaxWidth()) }

@Composable
internal fun DeviceScreen(container: AppContainer, onPair: () -> Unit) {
    RemotePage(container, DestinationData("devices", "devices"), title = "Bilgisayarlar", onPair = onPair)
}

@Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
internal fun PairingScreen(container: AppContainer, onBack: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var result by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<String?>(null) }
    var scanning by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var pendingLocalCode by remember { mutableStateOf<String?>(null) }
    val localNetworkPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val code = pendingLocalCode
        pendingLocalCode = null
        if (granted && code != null) {
            result = "Yerel PC bağlantısı doğrulanıyor…"
            scope.launch {
                result = runCatching { container.api.claimRelayOrLocalQr(code) }
                    .getOrElse { it.message ?: "Eşleşme tamamlanamadı." }
            }
        } else {
            result = "Yerel ağ izni verilmedi. Android ayarlarından izin verebilir veya internet relay QR kodunu kullanabilirsin."
        }
    }
    val scanner = androidx.compose.runtime.remember(context) { GmsBarcodeScanning.getClient(context) }
    Scaffold(topBar = {
        TopAppBar(
            title = { Text("PC eşleştir") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Geri") } },
        )
    }) { insets ->
        Column(Modifier.fillMaxSize().padding(insets).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Wiqo bilgisayar uygulamasındaki QR kodu tara.", style = MaterialTheme.typography.titleLarge)
            Text("QR kodun eşleşme bilgisi kısa süreli ve tek kullanımlıdır.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            androidx.compose.material3.Button(onClick = {
                scanning = true
                scanner.startScan()
                    .addOnSuccessListener { barcode ->
                        scanning = false
                        val value = barcode.rawValue
                        if (value.isNullOrBlank()) result = "QR kod okunamadı. Tekrar tara."
                        else {
                            if (value.startsWith("rova-pair:v1:") && android.os.Build.VERSION.SDK_INT >= 37 &&
                                context.checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") != android.content.pm.PackageManager.PERMISSION_GRANTED
                            ) {
                                pendingLocalCode = value
                                localNetworkPermission.launch("android.permission.ACCESS_LOCAL_NETWORK")
                            } else {
                                result = "QR okundu. Eşleşme tamamlanıyor…"
                                scope.launch {
                                    result = runCatching { container.api.claimRelayOrLocalQr(value) }
                                        .getOrElse { it.message ?: "Eşleşme tamamlanamadı." }
                                }
                            }
                        }
                    }
                    .addOnFailureListener { error -> scanning = false; result = error.localizedMessage ?: "QR kod açılamadı." }
                    .addOnCanceledListener { scanning = false }
            }, enabled = !scanning) {
                if (scanning) CircularProgressIndicator(Modifier.height(20.dp), strokeWidth = 2.dp)
                else { Icon(Icons.Filled.QrCodeScanner, null); Text("QR kodu tara", Modifier.padding(start = 8.dp)) }
            }
            result?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}

private fun String.toUiLabel(): String = when (this) {
    "status" -> "Durum"
    "tier" -> "Plan"
    "source" -> "Kaynak"
    "expiresAt" -> "Bitiş"
    "nextRunAt" -> "Sonraki çalışma"
    "lastRunAt" -> "Son çalışma"
    "isActive" -> "Etkin"
    "createdAt" -> "Oluşturulma"
    "email" -> "E-posta"
    "platform" -> "Platform"
    "displayName" -> "Cihaz"
    "accessLevel" -> "Erişim düzeyi"
    else -> this.replace(Regex("([a-z])([A-Z])"), "$1 $2").replaceFirstChar(Char::uppercase)
}

private fun emptyMessage(id: String): String = when (id) {
    "devices" -> "Henüz eşlenmiş bir PC yok."
    "history" -> "Henüz sohbet geçmişi yok."
    "tasks" -> "Bekleyen görev yok."
    "automations" -> "Henüz otomasyon yok."
    else -> "Burada henüz bir kayıt yok."
}
