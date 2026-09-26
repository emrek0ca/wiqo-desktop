package com.wiqo.android.ui

import android.app.Activity
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.speech.RecognizerIntent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.DocumentScanner
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.Surface
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateListOf
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.wiqo.android.AppContainer
import com.wiqo.android.data.local.LocalConversationMessage
import com.wiqo.android.data.attachments.ChatAttachment
import com.wiqo.android.data.attachments.AttachmentException
import com.wiqo.android.data.artifacts.ChatArtifact
import androidx.core.content.FileProvider
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import kotlinx.coroutines.launch

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun ChatScreen(
    container: AppContainer,
    conversationId: String = "default",
    onNewConversation: () -> Unit = {},
    onOpenRelated: (String, String?) -> Unit = { _, _ -> },
) {
    val vm: ChatViewModel = viewModel(key = "chat-$conversationId", factory = ChatViewModel.Factory(container, conversationId))
    val state by vm.state.collectAsStateWithLifecycle()
    var draft by rememberSaveable { mutableStateOf("") }
    val attachments = remember { mutableStateListOf<ChatAttachment>() }
    var attachmentError by rememberSaveable { mutableStateOf<String?>(null) }
    val keyboard = LocalSoftwareKeyboardController.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val listState = rememberLazyListState()
    var observedCompletedSends by remember(conversationId) { mutableStateOf(state.completedSends) }
    var previewError by remember(conversationId) { mutableStateOf<String?>(null) }
    val addUris: (List<android.net.Uri>) -> Unit = { uris ->
        scope.launch {
            try {
                attachments.addAll(container.attachments.load(uris))
                attachmentError = null
            } catch (error: AttachmentException) {
                attachmentError = error.message ?: "Dosya eklenemedi."
            } catch (_: Exception) {
                attachmentError = "Dosya açılamadı. Farklı bir dosya seçip tekrar dene."
            }
        }
    }
    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments(), addUris)
    val scannerOptions = remember {
        GmsDocumentScannerOptions.Builder()
            .setGalleryImportAllowed(true)
            .setPageLimit(10)
            .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_PDF)
            .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
            .build()
    }
    val documentScanner = remember(scannerOptions) { GmsDocumentScanning.getClient(scannerOptions) }
    val scanLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val pdf = GmsDocumentScanningResult.fromActivityResultIntent(result.data)?.getPdf()
            val uri = pdf?.getUri()
            if (uri != null) addUris(listOf(uri)) else attachmentError = "Tarama PDF olarak alınamadı."
        }
    }
    val speechLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val spoken = result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
            if (!spoken.isNullOrBlank()) draft = listOf(draft.trim(), spoken.trim()).filter(String::isNotBlank).joinToString(" ")
        }
    }
    fun startDocumentScan() {
        val activity = context as? Activity ?: run { attachmentError = "Belge tarayıcı açılamadı."; return }
        documentScanner.getStartScanIntent(activity)
            .addOnSuccessListener { sender -> scanLauncher.launch(IntentSenderRequest.Builder(sender).build()) }
            .addOnFailureListener { attachmentError = "Belge tarayıcı şu anda kullanılamıyor. Dosya seçiciyi kullanabilirsin." }
    }
    fun startSpeechInput() {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "tr-TR")
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Wiqo’ya anlat")
        }
        runCatching { speechLauncher.launch(intent) }
            .onFailure { attachmentError = "Bu cihazda konuşma tanıma kullanılamıyor." }
    }
    val audioPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startSpeechInput() else attachmentError = "Sesle yazmak için mikrofon izni gerekiyor."
    }
    LaunchedEffect(state.messages.size, state.sending) {
        val last = state.messages.lastIndex
        if (last >= 0) listState.animateScrollToItem(last)
    }
    LaunchedEffect(state.completedSends) {
        if (state.completedSends > observedCompletedSends) {
            observedCompletedSends = state.completedSends
            draft = ""
            attachments.clear()
            attachmentError = null
        }
    }
    state.error?.let { error ->
        AlertDialog(onDismissRequest = vm::dismissError, title = { Text("Yanıt alınamadı") }, text = { Text(error) }, confirmButton = { TextButton(onClick = vm::dismissError) { Text("Tamam") } })
    }
    previewError?.let { error ->
        AlertDialog(onDismissRequest = { previewError = null }, title = { Text("Dosya açılamadı") }, text = { Text(error) }, confirmButton = { TextButton(onClick = { previewError = null }) { Text("Tamam") } })
    }
    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Wiqo") },
            actions = { androidx.compose.material3.TextButton(onClick = onNewConversation) { Text("Yeni sohbet") } },
        )
    }) { insets ->
        Column(Modifier.fillMaxSize().padding(insets)) {
            if (state.messages.isEmpty() && !state.sending) {
                Column(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 28.dp), verticalArrangement = Arrangement.Center) {
                    Text("Ne yapmak istersin?", style = MaterialTheme.typography.headlineMedium)
                    Spacer(Modifier.height(8.dp))
                    Text("Wiqo’ya yaz. PC’ni eşleştirince bilgisayarındaki işlerde de yardımcı olabilir.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 20.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(state.messages, key = LocalConversationMessage::id) { message ->
                        MessageBubble(
                            message = message,
                            onOpenArtifact = { artifact ->
                                scope.launch {
                                    try {
                                        val file = container.artifacts.download(artifact)
                                        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
                                        val mimeType = if (artifact.mimeType == "text/html" || artifact.mimeType == "image/svg+xml") "text/plain" else artifact.mimeType
                                        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mimeType)
                                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                        context.startActivity(Intent.createChooser(intent, artifact.filename))
                                        previewError = null
                                    } catch (error: Exception) {
                                        previewError = error.message ?: "Dosya indirilemedi veya bu dosya türü açılamıyor."
                                    }
                                }
                            },
                            onOpenRelated = { id, target -> onOpenRelated(id, target) },
                        )
                    }
                    if (state.sending) item(key = "progress") {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(start = 8.dp)) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                            Text(state.progress ?: "Düşünüyor…", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                    if (state.partialReply.isNotEmpty()) item(key = "partial-reply") {
                        Card(shape = RoundedCornerShape(16.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
                            Column(Modifier.fillMaxWidth().padding(16.dp)) { MarkdownReply(state.partialReply) }
                        }
                    }
                }
            }
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                IconButton(onClick = { filePicker.launch(arrayOf("*/*")) }, enabled = !state.sending, modifier = Modifier.size(44.dp)) {
                    Icon(Icons.Filled.Add, contentDescription = "Dosya ekle")
                }
                OutlinedTextField(
                    value = draft,
                        onValueChange = { draft = it },
                        modifier = Modifier.weight(1f),
                    placeholder = { Text("Wiqo’ya mesaj yaz") },
                        maxLines = 5,
                        enabled = !state.sending,
                    shape = RoundedCornerShape(22.dp),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = {
                        val text = draft
                        keyboard?.hide()
                        vm.send(text, attachments.toList())
                    }),
                )
                IconButton(
                    onClick = { val text = draft; val pending = attachments.toList(); keyboard?.hide(); vm.send(text, pending) },
                    enabled = (draft.isNotBlank() || attachments.isNotEmpty()) && !state.sending,
                    modifier = Modifier.size(44.dp).background(MaterialTheme.colorScheme.primary, CircleShape),
                ) { Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Gönder", tint = MaterialTheme.colorScheme.onPrimary) }
            }
            if (attachments.isNotEmpty()) {
                androidx.compose.foundation.lazy.LazyRow(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(attachments.size) { index ->
                        val item = attachments[index]
                        Card(shape = RoundedCornerShape(14.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
                            Row(Modifier.padding(start = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(item.name, modifier = Modifier.widthIn(max = 180.dp).padding(vertical = 8.dp), maxLines = 1, style = MaterialTheme.typography.labelMedium)
                                IconButton(onClick = { attachments.removeAt(index) }, modifier = Modifier.size(32.dp)) {
                                    Icon(Icons.Filled.Close, contentDescription = "${item.name} ekini kaldır", modifier = Modifier.size(16.dp))
                                }
                            }
                        }
                    }
                }
            }
            if (attachmentError != null) {
                androidx.compose.material3.Text(
                    attachmentError.orEmpty(),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
                androidx.compose.material3.TextButton(onClick = { attachmentError = null }, modifier = Modifier.align(Alignment.End)) { Text("Kapat") }
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 2.dp), horizontalArrangement = Arrangement.End) {
                IconButton(onClick = ::startDocumentScan, enabled = !state.sending, modifier = Modifier.size(40.dp)) {
                    Icon(Icons.Filled.DocumentScanner, contentDescription = "Belge tara")
                }
                IconButton(
                    onClick = {
                        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                            startSpeechInput()
                        } else audioPermission.launch(Manifest.permission.RECORD_AUDIO)
                    },
                    enabled = !state.sending,
                    modifier = Modifier.size(40.dp),
                ) {
                    Icon(Icons.Filled.Mic, contentDescription = "Sesle yaz")
                }
            }
        }
    }
}

@Composable
private fun MessageBubble(
    message: LocalConversationMessage,
    onOpenArtifact: (ChatArtifact) -> Unit,
    onOpenRelated: (String, String?) -> Unit,
) {
    val user = message.role == "user"
    val metadata = remember(message.metadataJson) { parseMessageMetadata(message.metadataJson) }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (user) Arrangement.End else Arrangement.Start) {
        Card(
            modifier = Modifier.fillMaxWidth(if (user) 0.88f else 0.96f),
            shape = RoundedCornerShape(if (user) 20.dp else 16.dp),
            colors = CardDefaults.cardColors(containerColor = if (user) MaterialTheme.colorScheme.surfaceVariant else MaterialTheme.colorScheme.surface),
            elevation = CardDefaults.cardElevation(defaultElevation = if (user) 0.dp else 1.dp),
        ) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (user) {
                    metadata.attachmentNames.forEach { name ->
                        Text("📎 $name", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(message.content, style = MaterialTheme.typography.bodyLarge)
                } else {
                    MarkdownReply(message.content)
                    metadata.artifacts.forEach { artifact ->
                        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant), shape = RoundedCornerShape(12.dp)) {
                            Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(artifact.filename, Modifier.weight(1f), maxLines = 2, style = MaterialTheme.typography.bodyMedium)
                                TextButton(onClick = { onOpenArtifact(artifact) }) { Text("Önizle") }
                            }
                        }
                    }
                    metadata.related?.let { (title, route, id) ->
                        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer), shape = RoundedCornerShape(12.dp)) {
                            Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                                TextButton(onClick = { onOpenRelated(route, id) }) { Text("Ayrıntı") }
                            }
                        }
                    }
                    metadata.confirmations.forEach { confirmation ->
                        Surface(color = MaterialTheme.colorScheme.tertiaryContainer, shape = RoundedCornerShape(12.dp)) {
                            Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(confirmation.title, style = MaterialTheme.typography.titleSmall)
                                if (confirmation.summary.isNotBlank()) Text(confirmation.summary, style = MaterialTheme.typography.bodySmall)
                                TextButton(onClick = { onOpenRelated("activity", null) }) { Text("Etkinlik’te gözden geçir") }
                            }
                        }
                    }
                }
            }
        }
    }
}
