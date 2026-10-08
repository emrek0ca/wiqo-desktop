package com.wiqo.android.ui

import android.content.Context
import android.content.ContextWrapper
import android.app.Activity
import android.net.Uri
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebChromeClient
import android.webkit.ConsoleMessage
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
import com.wiqo.android.AppContainer
import com.wiqo.android.data.act.ActBundler
import com.wiqo.android.data.act.ActProject
import com.wiqo.android.data.act.ActProjectRules
import com.wiqo.android.data.act.ActQuickEdits
import com.wiqo.android.data.act.ActPageCapture
import com.wiqo.android.data.act.ActRepository
import com.wiqo.android.data.act.ActVault
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import java.io.ByteArrayInputStream
import java.io.FileOutputStream
import java.io.OutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Root integration: call ActScreen(container, onBack, optionalProjectId). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ActScreen(
    container: AppContainer,
    onBack: () -> Unit,
    initialProjectId: String? = null,
    initialRequest: String? = null,
) {
    val context = LocalContext.current
    val repo = remember(container.api.currentAccountId()) { ActRepository(context, container.api) }
    val scope = rememberCoroutineScope()
    val projects = remember { mutableStateListOf<ActProject>() }
    var selectedId by remember { mutableStateOf(initialProjectId) }
    val selected = projects.firstOrNull { it.id == selectedId }
    var tab by remember(selectedId) { mutableStateOf("Önizleme") }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var jobMessage by remember { mutableStateOf<String?>(null) }
    var writerId by remember { mutableStateOf<String?>(null) }
    var activeJob by remember { mutableStateOf<Job?>(null) }
    var draft by remember { mutableStateOf("") }
    var mode by remember { mutableStateOf("devices") }
    var showConsent by remember { mutableStateOf(false) }
    var showRecovery by remember { mutableStateOf(false) }
    var recoveryInput by remember { mutableStateOf("") }
    var deleteTarget by remember { mutableStateOf<ActProject?>(null) }
    var editingPath by remember { mutableStateOf<String?>(null) }
    var editorNewPath by remember { mutableStateOf("") }
    var editorText by remember { mutableStateOf("") }
    var fileDeleteTarget by remember { mutableStateOf<String?>(null) }
    var newPath by remember { mutableStateOf<String?>(null) }
    var pendingExport by remember { mutableStateOf<ActProject?>(null) }
    var pendingHtml by remember { mutableStateOf<ActProject?>(null) }
    var pendingCapture by remember { mutableStateOf<Pair<ActProject, ActPageCapture.Output>?>(null) }
    var importUris by remember { mutableStateOf<List<Uri>?>(null) }
    val consoleErrors = remember(selectedId) { mutableStateListOf<String>() }
    var previewHtml by remember(selectedId) { mutableStateOf<String?>(null) }
    var previewError by remember(selectedId) { mutableStateOf<String?>(null) }

    LaunchedEffect(initialProjectId, initialRequest) {
        if (initialProjectId != null) selectedId = initialProjectId
        if (!initialRequest.isNullOrBlank()) draft = initialRequest.take(1200)
    }
    LaunchedEffect(selected?.id, selected?.files, tab) {
        if (selected?.kind == "web" && tab == "Önizleme") {
            previewHtml = null; previewError = null; consoleErrors.clear()
            runCatching { repo.readyPage(selected) }
                .onSuccess { previewHtml = it }
                .onFailure { previewError = it.message ?: "Sayfa hazırlanamadı." }
        }
    }

    suspend fun refresh() {
        projects.clear()
        projects.addAll(repo.local.all())
    }
    fun showFailure(cause: Throwable) { error = cause.message ?: "İşlem tamamlanamadı." }
    fun runAction(action: suspend () -> Unit) {
        scope.launch {
            busy = true; error = null
            try { action(); refresh() } catch (cause: Exception) { showFailure(cause) }
            finally { busy = false }
        }
    }
    LaunchedEffect(repo) {
        runCatching { refresh() }.onFailure(::showFailure)
        runCatching { repo.syncAll(); refresh() }.onSuccess {
            if (repo.inaccessibleProjects > 0) notice = "${repo.inaccessibleProjects} şifreli proje bu anahtarla açılamadı. Önceki cihazın kurtarma kodunu gir."
        }.onFailure { notice = "Projeler eşitlenemedi: ${it.message ?: "Bağlantıyı kontrol et."}" }
    }
    val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        val target = pendingExport
        pendingExport = null
        if (uri != null && target != null) runAction { exportZip(context, target, uri); notice = "Proje ZIP dosyası kaydedildi." }
    }
    val htmlLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/html")) { uri ->
        val target = pendingHtml; pendingHtml = null
        if (uri != null && target != null) runAction {
            val page = repo.readyPage(target)
            writeDocument(context, uri, page.toByteArray(Charsets.UTF_8))
            notice = "Tek HTML dosyası kaydedildi."
        }
    }
    val pdfLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/pdf")) { uri ->
        val pending = pendingCapture; pendingCapture = null
        if (uri != null && pending != null) runAction {
            val activity = context.findActivity() ?: throw IllegalStateException("Sayfa yakalama için açık ekran gerekli.")
            val page = repo.readyPage(pending.first)
            writeDocument(context, uri, ActPageCapture.capture(activity, page, output = ActPageCapture.Output.PDF))
            notice = "PDF kaydedildi."
        }
    }
    val pngLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/png")) { uri ->
        val pending = pendingCapture; pendingCapture = null
        if (uri != null && pending != null) runAction {
            val activity = context.findActivity() ?: throw IllegalStateException("Sayfa yakalama için açık ekran gerekli.")
            val page = repo.readyPage(pending.first)
            writeDocument(context, uri, ActPageCapture.capture(activity, page, output = ActPageCapture.Output.PNG))
            notice = "Görsel kaydedildi."
        }
    }
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) importUris = uris
    }

    fun beginWriter() {
        val request = draft.trim()
        val project = selected
        if (request.length < if (project == null) 3 else 2) { error = "İsteği biraz daha açık yaz."; return }
        if (request.length > 1200) { error = "İstek en fazla 1200 karakter olabilir."; return }
        if (project?.kind == "web") {
            val quick = ActQuickEdits.apply(request, project.files)
            if (quick != null) {
                runAction {
                    val files = (project.files + quick.changed).toMutableMap()
                    files["PROJE.md"]?.let { note -> files["PROJE.md"] = (note.lines() + "- ${quick.summary.take(140)}").takeLast(35).joinToString("\n") }
                    repo.saveFiles(project.id, files, quick.summary)
                    if (project.mode == "devices") runCatching { repo.sync(project.id) }
                        .onFailure { notice = "Hızlı değişiklik cihazda kaydedildi; senkron bekliyor: ${it.message}" }
                    draft = ""
                }
                return
            }
        }
        val prefs = context.getSharedPreferences("act_writer_consent", Context.MODE_PRIVATE)
        if (project?.mode == "deviceOnly" || !prefs.getBoolean("granted", false)) { showConsent = true; return }
        activeJob = scope.launch {
            busy = true; error = null; jobMessage = "Yazıcı başlatılıyor"
            try {
                val id = repo.startWriter(if (project == null) "create" else "edit", request, project, consoleErrors.toList())
                writerId = id
                val state = repo.awaitWriter(id) { jobMessage = it }
                if (state.status != "done" || state.result == null) throw IllegalStateException(state.error ?: "Kod üretilemedi; aynı isteği yeniden deneyebilirsin.")
                val saved = repo.commitWriter(state.result, project, request, mode)
                repo.lastVerificationNote?.let { notice = it }
                repo.acknowledgeWriter(id)
                writerId = null
                if (saved.mode == "devices") runCatching { repo.sync(saved.id) }.onFailure { notice = "Proje cihazda kaydedildi; şifreli senkron bekliyor: ${it.message}" }
                selectedId = saved.id; draft = ""; refresh()
            } catch (cancelled: kotlinx.coroutines.CancellationException) { notice = "Görev durduruldu; proje değişmedi." }
            catch (cause: Exception) { showFailure(cause) }
            finally { busy = false; jobMessage = null; activeJob = null }
        }
    }

    Scaffold(topBar = { TopAppBar(title = { Text(selected?.name ?: "Act") }, navigationIcon = {
        TextButton(onClick = { if (selected != null) selectedId = null else onBack() }) { Text("Geri") }
    }, actions = {
        TextButton(enabled = !busy, onClick = { runAction {
            repo.syncAll()
            notice = if (repo.inaccessibleProjects > 0) "${repo.inaccessibleProjects} proje bu anahtarla açılamadı; kurtarma kodunu gir."
            else "Projeler eşitlendi."
        } }) { Text("Eşitle") }
    }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp)) {
            if (busy && jobMessage == null) CircularProgressIndicator()
            if (jobMessage != null) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CircularProgressIndicator(); Text(jobMessage.orEmpty()); TextButton(onClick = {
                    activeJob?.cancel(); writerId?.let { id -> scope.launch { runCatching { repo.cancelWriter(id) } } }
                }) { Text("Durdur") }
            }
            error?.let { Text(it, color = androidx.compose.material3.MaterialTheme.colorScheme.error); TextButton(onClick = { error = null }) { Text("Kapat") } }
            notice?.let { Text(it); TextButton(onClick = { notice = null }) { Text("Kapat") } }
            if (selected == null) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = mode == "devices", onClick = { mode = "devices" }, label = { Text("Bağlı cihazlarım") })
                    FilterChip(selected = mode == "deviceOnly", onClick = { mode = "deviceOnly" }, label = { Text("Yalnız bu cihaz") })
                }
                Text("Projeler", style = androidx.compose.material3.MaterialTheme.typography.titleLarge)
                LazyColumn(Modifier.weight(1f)) {
                    items(projects, key = { it.id }) { p ->
                        Column(Modifier.fillMaxWidth().clickable { selectedId = p.id }.padding(vertical = 13.dp)) {
                            Text(p.name, style = androidx.compose.material3.MaterialTheme.typography.titleMedium)
                            Text("${if (p.kind == "python") "Python" else "Web"} · ${p.files.size} dosya · ${if (p.mode == "devices") "Şifreli senkron" else "Yalnız cihaz"}")
                        }
                        HorizontalDivider()
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { importLauncher.launch(arrayOf("text/*", "application/json", "application/javascript")) }) { Text("Dosya içe aktar") }
                    TextButton(onClick = { showRecovery = true }) { Text("Kurtarma kodu") }
                }
            } else {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("Önizleme", "Dosyalar", "Geçmiş").forEach { title ->
                        FilterChip(selected = tab == title, onClick = { tab = title }, label = { Text(title) })
                    }
                }
                when (tab) {
                    "Önizleme" -> {
                        if (selected.kind == "web") {
                            val page = previewHtml
                            if (page != null) ActPreview(selected.id, page, Modifier.weight(1f)) { message ->
                                if (message !in consoleErrors && consoleErrors.size < 20) consoleErrors.add(message.take(1000))
                            } else Box(Modifier.weight(1f)) { Text(previewError ?: "Sayfa hazırlanıyor…") }
                        }
                        else Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                            Text("Python programı")
                            OutlinedButton(onClick = { runAction {
                                val response = container.api.post("code-sync/run", buildJsonObject {
                                    put("files", buildJsonArray { selected.files.forEach { (path, content) -> add(buildJsonObject { put("path", path); put("content", content) }) } })
                                }) as? JsonObject
                                notice = listOfNotNull((response?.get("stdout") as? JsonPrimitive)?.contentOrNull,
                                    (response?.get("stderr") as? JsonPrimitive)?.contentOrNull).joinToString("\n").take(10_000)
                            } }) { Text("Güvenli sunucuda çalıştır") }
                            selected.files.filterKeys { it.endsWith(".py") }.forEach { (path, content) -> Text("$path\n$content") }
                        }
                    }
                    "Dosyalar" -> LazyColumn(Modifier.weight(1f)) {
                        items(selected.files.keys.sorted()) { path ->
                            TextButton(onClick = { editingPath = path; editorNewPath = path; editorText = selected.files[path].orEmpty() }) { Text(path) }
                        }
                        item { OutlinedButton(onClick = { newPath = "" }) { Text("Yeni dosya") } }
                    }
                    else -> LazyColumn(Modifier.weight(1f)) {
                        items(selected.history, key = { it.id }) { entry ->
                            Column(Modifier.padding(vertical = 8.dp)) {
                                Text(entry.summary)
                                Text("${entry.source} · ${if (entry.verified) "Kaydedildi" else "Önizleme ile kontrol et"}")
                                if (selected.history.firstOrNull()?.id != entry.id) TextButton(onClick = { runAction {
                                    repo.restore(selected.id, entry.id)
                                    if (selected.mode == "devices") repo.sync(selected.id)
                                } }) { Text("Bu sürüme dön") }
                            }
                            HorizontalDivider()
                        }
                    }
                }
                if (consoleErrors.isNotEmpty()) {
                    Text("Önizleme hatası: ${consoleErrors.first().take(180)}")
                    TextButton(onClick = { draft = "Önizleme hatalarını düzelt, başka bir şey değiştirme: " + consoleErrors.take(5).joinToString("; ").take(900) }) { Text("Düzelt") }
                }
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = { runAction { repo.undo(selected.id); if (selected.mode == "devices") repo.sync(selected.id) } }, enabled = !busy && selected.history.size >= 2) { Text("Geri al") }
                    TextButton(onClick = { pendingExport = selected; exportLauncher.launch("${selected.name.take(50)}.zip") }) { Text("ZIP") }
                    if (selected.kind == "web") {
                        TextButton(onClick = { pendingHtml = selected; htmlLauncher.launch("${selected.name.take(50)}.html") }) { Text("HTML") }
                        TextButton(onClick = { pendingCapture = selected to ActPageCapture.Output.PDF; pdfLauncher.launch("${selected.name.take(50)}.pdf") }) { Text("PDF") }
                        TextButton(onClick = { pendingCapture = selected to ActPageCapture.Output.PNG; pngLauncher.launch("${selected.name.take(50)}.png") }) { Text("PNG") }
                    }
                    TextButton(onClick = { runAction { val copy = repo.duplicate(selected.id); if (copy.mode == "devices") repo.sync(copy.id) } }) { Text("Kopyala") }
                    TextButton(onClick = { runAction {
                        val next = if (selected.mode == "devices") "deviceOnly" else "devices"
                        repo.changeMode(selected.id, next)
                        if (next == "devices") repo.sync(selected.id)
                    } }) { Text(if (selected.mode == "devices") "Yalnız cihaz" else "Şifreli eşitle") }
                    TextButton(onClick = { deleteTarget = selected }) { Text("Sil") }
                }
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("open_preview" to "PC'de önizle", "open_editor" to "PC editörü", "open_folder" to "PC klasörü", "run" to "PC'de çalıştır").forEach { (action, title) ->
                        TextButton(enabled = !busy && selected.mode == "devices", onClick = { runAction {
                            jobMessage = "PC'nin yanıtı bekleniyor…"
                            try { notice = repo.handOff(selected.id, action) { jobMessage = it } }
                            finally { jobMessage = null }
                        } }) { Text(title) }
                    }
                }
                selected.files.keys.filter { it.contains(" - Android kopyası") }.forEach { copy ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Çakışma: $copy")
                        TextButton(onClick = { runAction { repo.resolveConflict(selected.id, copy, true); if (selected.mode == "devices") repo.sync(selected.id) } }) { Text("Kullan") }
                        TextButton(onClick = { runAction { repo.resolveConflict(selected.id, copy, false); if (selected.mode == "devices") repo.sync(selected.id) } }) { Text("Sil") }
                    }
                }
            }
            OutlinedTextField(value = draft, onValueChange = { draft = it.take(1200) }, modifier = Modifier.fillMaxWidth(),
                label = { Text(if (selected == null) "Ne yapalım?" else "Bu projede ne değişsin?") }, minLines = 2, maxLines = 4)
            Button(onClick = ::beginWriter, enabled = !busy && draft.trim().length >= if (selected == null) 3 else 2,
                modifier = Modifier.fillMaxWidth()) { Text(if (selected == null) "Proje oluştur" else "Değiştir") }
            Spacer(Modifier.height(8.dp))
        }
    }
    if (showConsent) AlertDialog(onDismissRequest = { showConsent = false }, title = { Text("Yazara gönderilecek") },
        text = { Text("Bu isteği işlemek için proje dosyaları yazıcı modele gönderilir. Cihazlar arası senkron kopyaları şifrelidir.") },
        confirmButton = { TextButton(onClick = {
            showConsent = false
            context.getSharedPreferences("act_writer_consent", Context.MODE_PRIVATE).edit().putBoolean("granted", true).apply()
            // deviceOnly still requires fresh consent; this invocation is already approved.
            activeJob = scope.launch {
                busy = true; jobMessage = "Yazıcı başlatılıyor"; error = null
                try {
                    val project = selected; val request = draft.trim()
                    val id = repo.startWriter(if (project == null) "create" else "edit", request, project, consoleErrors.toList())
                    writerId = id
                    val state = repo.awaitWriter(id) { jobMessage = it }
                    if (state.status != "done" || state.result == null) throw IllegalStateException(state.error ?: "Kod üretilemedi.")
                    val saved = repo.commitWriter(state.result, project, request, mode)
                    repo.lastVerificationNote?.let { notice = it }
                    repo.acknowledgeWriter(id); writerId = null
                    if (saved.mode == "devices") runCatching { repo.sync(saved.id) }.onFailure { notice = "Cihazda kaydedildi; senkron bekliyor: ${it.message}" }
                    selectedId = saved.id; draft = ""; refresh()
                } catch (cancelled: kotlinx.coroutines.CancellationException) { notice = "Görev durduruldu." }
                catch (cause: Exception) { showFailure(cause) }
                finally { busy = false; jobMessage = null; activeJob = null }
            }
        }) { Text("Devam et") } }, dismissButton = { TextButton(onClick = { showConsent = false }) { Text("Vazgeç") } })
    deleteTarget?.let { target -> AlertDialog(onDismissRequest = { deleteTarget = null }, title = { Text("Proje silinsin mi?") },
        text = { Text("${target.name}: dosyalar ve geçmiş silinir.") },
        confirmButton = { TextButton(onClick = { deleteTarget = null; runAction { repo.delete(target.id); if (selectedId == target.id) selectedId = null } }) { Text("Sil") } },
        dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Vazgeç") } }) }
    editingPath?.let { path -> AlertDialog(onDismissRequest = { editingPath = null }, title = { Text(path) },
        text = { Column { OutlinedTextField(value = editorNewPath, onValueChange = { editorNewPath = it.take(80) }, label = { Text("Dosya adı") })
            OutlinedTextField(value = editorText, onValueChange = { editorText = it.take(100_000) }, minLines = 12, maxLines = 20) } },
        confirmButton = { TextButton(onClick = {
            val renamed = editorNewPath.trim()
            if (!ActProjectRules.valid(renamed, editorText) || (renamed != path && selected?.files?.containsKey(renamed) == true)) {
                error = "Dosya adı geçersiz, çok büyük veya zaten var."
            } else { editingPath = null; selected?.let { p -> runAction {
                val updated = p.files.toMutableMap().apply { remove(path); put(renamed, editorText) }
                repo.saveFiles(p.id, updated, "$path düzenlendi")
                if (p.mode == "devices") runCatching { repo.sync(p.id) }.onFailure { notice = "Senkron bekliyor: ${it.message}" }
            } } }
        }) { Text("Kaydet") } },
        dismissButton = { Row {
            TextButton(onClick = { editingPath = null; fileDeleteTarget = path }) { Text("Dosyayı sil") }
            TextButton(onClick = { editingPath = null }) { Text("Vazgeç") }
        } }) }
    fileDeleteTarget?.let { path -> AlertDialog(onDismissRequest = { fileDeleteTarget = null }, title = { Text("$path silinsin mi?") },
        confirmButton = { TextButton(onClick = { fileDeleteTarget = null; selected?.let { p -> runAction {
            repo.saveFiles(p.id, p.files - path, "$path silindi")
            if (p.mode == "devices") repo.sync(p.id)
        } } }) { Text("Sil") } },
        dismissButton = { TextButton(onClick = { fileDeleteTarget = null }) { Text("Vazgeç") } }) }
    newPath?.let { path -> AlertDialog(onDismissRequest = { newPath = null }, title = { Text("Yeni dosya") },
        text = { OutlinedTextField(value = path, onValueChange = { newPath = it.take(80) }, label = { Text("Dosya adı (örn. style.css)") }) },
        confirmButton = { TextButton(onClick = { if (!ActProjectRules.valid(path, "") || selected?.files?.containsKey(path) == true) error = "Dosya adı geçersiz veya zaten var." else {
            newPath = null; selected?.let { p -> runAction {
                repo.saveFiles(p.id, p.files + (path to ""), "$path eklendi")
                if (p.mode == "devices") runCatching { repo.sync(p.id) }.onFailure { notice = "Senkron bekliyor: ${it.message}" }
            } }
        } }) { Text("Ekle") } }, dismissButton = { TextButton(onClick = { newPath = null }) { Text("Vazgeç") } }) }
    if (showRecovery) AlertDialog(onDismissRequest = { showRecovery = false }, title = { Text("Act kurtarma kodu") },
        text = { Column { Text("Bu kodu güvenli bir yerde sakla. Diğer cihazlarda aynı şifreli projeleri açar.")
            Text(runCatching { repo.vaults.loadOrCreate().recoveryCode() }.getOrElse { "Bu cihazdaki anahtar açılamadı; kurtarma kodunu gir." })
            OutlinedTextField(value = recoveryInput, onValueChange = { recoveryInput = it }, label = { Text("Başka cihazın kodunu gir") }) } },
        confirmButton = { TextButton(onClick = {
            val parsed = ActVault.fromRecoveryCode(recoveryInput)
            if (parsed == null) error = "Kurtarma kodu geçersiz." else if (repo.vaults.load() != null && projects.any { it.mode == "devices" && it.hubId != null }) error = "Önce mevcut şifreli projeleri yedekle; anahtar değiştirilemez."
            else runCatching { repo.vaults.save(parsed) }
                .onSuccess { showRecovery = false; runAction { repo.syncAll() } }
                .onFailure(::showFailure)
        }) { Text("Kodu kullan") } }, dismissButton = { TextButton(onClick = { showRecovery = false }) { Text("Bitti") } })
    importUris?.let { uris -> LaunchedEffect(uris) {
        importUris = null
        busy = true
        try {
            val files = readImportedFiles(context, uris)
            val isPython = files.keys.any { it.endsWith(".py") } && files.keys.none { it.endsWith(".html") }
            val name = files.keys.firstOrNull()?.substringBeforeLast('.') ?: "İçe aktarılan proje"
            val project = repo.createLocal(name.take(60), if (isPython) "python" else "web", mode, files)
            selectedId = project.id; refresh()
            if (mode == "devices") runCatching { repo.sync(project.id) }.onFailure { notice = "Proje cihazda kaydedildi; senkron bekliyor: ${it.message}" }
        } catch (cause: Exception) { showFailure(cause) }
        finally { busy = false }
    } }
}

@Composable
private fun ActPreview(projectId: String, page: String, modifier: Modifier = Modifier, onError: (String) -> Unit = {}) {
    key(projectId) { AndroidView(modifier = modifier.fillMaxWidth(), factory = { context -> WebView(context).apply {
        settings.javaScriptEnabled = true
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.domStorageEnabled = true
        settings.javaScriptCanOpenWindowsAutomatically = false
        webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(message: ConsoleMessage?): Boolean {
                if (message?.messageLevel() == ConsoleMessage.MessageLevel.ERROR) onError(message.message())
                return true
            }
        }
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = true
            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? =
                WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))
        }
        tag = page
        loadDataWithBaseURL("https://act.wiqo.local/", page, "text/html", "UTF-8", null)
    } }, update = {
        if (it.tag != page) {
            it.tag = page
            it.loadDataWithBaseURL("https://act.wiqo.local/", page, "text/html", "UTF-8", null)
        }
    }, onRelease = { it.destroy() }) }
}

private suspend fun readImportedFiles(context: Context, uris: List<Uri>): Map<String, String> = withContext(Dispatchers.IO) {
    require(uris.size in 1..40) { "En fazla 40 dosya içe aktarılabilir." }
    val files = linkedMapOf<String, String>()
    uris.forEach { uri ->
        val cursor = context.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)
        val name = cursor?.use { if (it.moveToFirst()) it.getString(0) else null } ?: throw IllegalStateException("Dosya adı okunamadı.")
        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readNBytes(100 * 1024 + 1) }
            ?: throw IllegalStateException("$name okunamadı.")
        require(bytes.size <= 100 * 1024) { "$name çok büyük." }
        val text = bytes.toString(Charsets.UTF_8)
        require(ActProjectRules.valid(name, text) && name !in files) { "$name desteklenmiyor veya yineleniyor." }
        files[name] = text
    }
    files
}

private suspend fun exportZip(context: Context, project: ActProject, uri: Uri) = withContext(Dispatchers.IO) {
    context.contentResolver.openOutputStream(uri, "w")?.use { raw ->
        ZipOutputStream(raw).use { zip ->
            project.files.toSortedMap().forEach { (path, content) ->
                require(ActProjectRules.valid(path, content))
                zip.putNextEntry(ZipEntry(path))
                zip.write(content.toByteArray(Charsets.UTF_8))
                zip.closeEntry()
            }
        }
    } ?: throw IllegalStateException("ZIP dosyası açılamadı.")
}

private suspend fun writeDocument(context: Context, uri: Uri, bytes: ByteArray) = withContext(Dispatchers.IO) {
    context.contentResolver.openOutputStream(uri, "w")?.use { it.write(bytes) }
        ?: throw IllegalStateException("Dosya açılamadı.")
}

private fun Context.findActivity(): Activity? {
    var current: Context? = this
    while (current != null) {
        if (current is Activity) return current
        current = (current as? ContextWrapper)?.baseContext
    }
    return null
}
