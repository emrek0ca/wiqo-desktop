package com.wiqo.android.ui

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.DocumentScanner
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.automirrored.outlined.VolumeDown
import androidx.compose.material.icons.outlined.Calculate
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.DocumentScanner
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Nightlight
import androidx.compose.material.icons.outlined.PersonAdd
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.TableChart
import androidx.compose.material.icons.outlined.VolumeDown
import androidx.compose.material.icons.outlined.WbSunny
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.wiqo.android.AppContainer
import com.wiqo.android.R
import com.wiqo.android.data.attachments.AttachmentException
import com.wiqo.android.data.attachments.ChatAttachment
import com.wiqo.android.data.local.LocalConversationMessage
import com.wiqo.android.ui.components.RovaConnectionIcon
import com.wiqo.android.ui.components.ThinkingLiveView
import com.wiqo.android.ui.components.WiqoApprovalCard
import com.wiqo.android.ui.components.WiqoApprovalField
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoSans
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private data class QuickSuggestion(val title: String, val icon: ImageVector? = null)

private val quickSuggestions = listOf(
    QuickSuggestion("Bugün hava nasıl?", Icons.Outlined.WbSunny),
    QuickSuggestion("Basit bir hesap makinesi yap", Icons.Outlined.Calculate),
    QuickSuggestion("Dosya bul ve gönder", Icons.Outlined.Search),
    QuickSuggestion("Sesi kıs", Icons.Outlined.VolumeDown),
    QuickSuggestion("Ekranı kısarak odaklan", Icons.Outlined.Nightlight),
    QuickSuggestion("Toplantıya hazırla", Icons.Outlined.CalendarMonth),
    QuickSuggestion("Bu ayki bütçemi tabloya dök", Icons.Outlined.TableChart),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ChatScreen(
    container: AppContainer,
    conversationId: String = "default",
    onOpenSidebar: () -> Unit = {},
    onOpenPCSettings: () -> Unit = {},
    onOpenTemplates: () -> Unit = {},
    onNewConversation: () -> Unit = {},
    onOpenRelated: (String, String?) -> Unit = { _, _ -> },
    draftPrompt: String? = null,
    isPaired: Boolean = false,
    isConnected: Boolean = false,
) {
    val colors = WiqoDesign.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val keyboard = LocalSoftwareKeyboardController.current

    val vm: ChatViewModel = viewModel(key = "chat-$conversationId", factory = ChatViewModel.Factory(container, conversationId))
    val state by vm.state.collectAsStateWithLifecycle()

    var draft by rememberSaveable { mutableStateOf(draftPrompt ?: "") }
    val attachments = remember { mutableStateListOf<ChatAttachment>() }
    var isComposerFocused by remember { mutableStateOf(false) }
    var isCreatingAgent by remember { mutableStateOf(false) }
    var isRecordingAudio by remember { mutableStateOf(false) }
    var showPlusMenu by remember { mutableStateOf(false) }
    var attachmentError by rememberSaveable { mutableStateOf<String?>(null) }
    val listState = rememberLazyListState()

    LaunchedEffect(draftPrompt) {
        if (!draftPrompt.isNullOrBlank()) {
            draft = draftPrompt
        }
    }

    val addUris: (List<android.net.Uri>) -> Unit = { uris ->
        scope.launch {
            try {
                attachments.addAll(container.attachments.load(uris))
                attachmentError = null
            } catch (error: AttachmentException) {
                attachmentError = error.message ?: "Dosya eklenemedi."
            } catch (_: Exception) {
                attachmentError = "Dosya açılamadı. Tekrar dene."
            }
        }
    }

    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments(), addUris)
    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents(), addUris)

    val scannerOptions = remember {
        GmsDocumentScannerOptions.Builder()
            .setGalleryImportAllowed(true)
            .setPageLimit(10)
            .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_PDF)
            .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
            .build()
    }
    val documentScanner = remember(context) { GmsDocumentScanning.getClient(scannerOptions) }
    val scanLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val pdf = GmsDocumentScanningResult.fromActivityResultIntent(result.data)?.getPdf()
            val uri = pdf?.getUri()
            if (uri != null) addUris(listOf(uri))
        }
    }

    val speechLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        isRecordingAudio = false
        if (result.resultCode == Activity.RESULT_OK) {
            val spoken = result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
            if (!spoken.isNullOrBlank()) {
                draft = listOf(draft.trim(), spoken.trim()).filter(String::isNotBlank).joinToString(" ")
            }
        }
    }

    fun startSpeechInput() {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "tr-TR")
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Wiqo'ya anlat")
        }
        runCatching {
            isRecordingAudio = true
            speechLauncher.launch(intent)
        }.onFailure {
            isRecordingAudio = false
            attachmentError = "Ses tanıma bu cihazda kullanılamıyor."
        }
    }

    val audioPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startSpeechInput() else attachmentError = "Ses kaydı için mikrofon izni gerekiyor."
    }

    LaunchedEffect(state.messages.size, state.sending) {
        val last = state.messages.lastIndex
        if (last >= 0) listState.animateScrollToItem(last)
    }

    val canSend = draft.isNotBlank() || attachments.isNotEmpty()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.systemBackground)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding(),
    ) {
        // iOS Top Bar Parity matching screenshot
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Left: Hamburger menu in circular white container with hairline border
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(colors.canvas)
                    .border(1.dp, colors.line, CircleShape)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onOpenSidebar,
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Default.Menu,
                    contentDescription = "Sohbet geçmişi",
                    tint = colors.ink,
                    modifier = Modifier.size(20.dp),
                )
            }

            Spacer(Modifier.weight(1f))

            // Right: Unified capsule container with hairline border
            Row(
                modifier = Modifier
                    .height(40.dp)
                    .clip(CircleShape)
                    .background(colors.canvas)
                    .border(1.dp, colors.line, CircleShape)
                    .padding(horizontal = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Box(
                    modifier = Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onOpenPCSettings,
                    ),
                    contentAlignment = Alignment.Center,
                ) {
                    RovaConnectionIcon(isPaired = isPaired, isConnected = isConnected)
                }

                Box(
                    modifier = Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onOpenTemplates,
                    ),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Outlined.History,
                        contentDescription = "Otomasyon şablonları",
                        tint = colors.ink,
                        modifier = Modifier.size(20.dp),
                    )
                }

                Box(
                    modifier = Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onNewConversation,
                    ),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Edit,
                        contentDescription = "Yeni sohbet",
                        tint = colors.ink,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
        }

        // Main Chat Area
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
        ) {
            if (state.messages.isEmpty() && !state.sending) {
                // Empty State: ONLY the minimalist Wiqo mark in the center
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 24.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Image(
                        painter = painterResource(if (colors.isDark) R.drawable.wiqo_mark_dark else R.drawable.wiqo_mark),
                        contentDescription = "Wiqo",
                        modifier = Modifier.size(68.dp),
                    )
                }
            } else {
                // Messages List
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        horizontal = 16.dp,
                        vertical = 12.dp,
                    ),
                ) {
                    items(state.messages, key = LocalConversationMessage::id) { message ->
                        val metadata = remember(message.metadataJson) { parseMessageMetadata(message.metadataJson) }
                        val isUser = message.role == "user"

                        if (isUser) {
                            // User Message Bubble matching iOS
                            Column(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalAlignment = Alignment.End,
                            ) {
                                if (metadata.attachmentNames.isNotEmpty()) {
                                    Row(
                                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                                        modifier = Modifier.padding(bottom = 6.dp),
                                    ) {
                                        metadata.attachmentNames.forEach { name ->
                                            Box(
                                                modifier = Modifier
                                                    .background(colors.inset, RoundedCornerShape(8.dp))
                                                    .padding(horizontal = 8.dp, vertical = 4.dp),
                                            ) {
                                                Text(
                                                    text = name,
                                                    fontFamily = WiqoSans,
                                                    fontSize = 11.sp,
                                                    color = colors.ink.copy(alpha = 0.7f),
                                                )
                                            }
                                        }
                                    }
                                }

                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.End,
                                ) {
                                    Spacer(Modifier.widthIn(min = 40.dp))
                                    Box(
                                        modifier = Modifier
                                            .clip(RoundedCornerShape(WiqoDesign.BubbleRadius))
                                            .background(colors.secondarySystemBackground)
                                            .padding(horizontal = 14.dp, vertical = 10.dp),
                                    ) {
                                        SelectionContainer {
                                            Text(
                                                text = message.content,
                                                fontFamily = WiqoSans,
                                                fontSize = 15.sp,
                                                lineHeight = 22.sp,
                                                color = colors.ink,
                                            )
                                        }
                                    }
                                }
                            }
                        } else if (message.role == "system") {
                            // System Error View matching iOS
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .background(colors.tint(colors.red), RoundedCornerShape(14.dp))
                                    .padding(12.dp),
                            ) {
                                Row(verticalAlignment = Alignment.Top) {
                                    Icon(Icons.Default.Warning, contentDescription = null, tint = colors.red, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(8.dp))
                                    Text(
                                        text = message.content,
                                        fontFamily = WiqoSans,
                                        fontSize = 13.sp,
                                        color = colors.red,
                                    )
                                }
                            }
                        } else {
                            // Assistant Message: Clean, Borderless layout matching iOS
                            val clipboardManager = LocalClipboardManager.current
                            var copied by remember { mutableStateOf(false) }

                            Column(
                                modifier = Modifier.fillMaxWidth(),
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                MarkdownReply(text = message.content)

                                if (metadata.confirmations.isNotEmpty()) {
                                    metadata.confirmations.forEach { confirmation ->
                                        WiqoApprovalCard(
                                            title = confirmation.title,
                                            summary = confirmation.summary,
                                            onApprove = {},
                                            onDecline = {},
                                        )
                                    }
                                }

                                // Copy Reply button matching iOS CopyReplyButton
                                Row(
                                    modifier = Modifier
                                        .clickable(
                                            interactionSource = remember { MutableInteractionSource() },
                                            indication = null,
                                            onClick = {
                                                clipboardManager.setText(AnnotatedString(message.content))
                                                copied = true
                                                scope.launch {
                                                    delay(1500)
                                                    copied = false
                                                }
                                            },
                                        )
                                        .padding(vertical = 4.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Icon(
                                        imageVector = if (copied) Icons.Default.Check else Icons.Default.ContentCopy,
                                        contentDescription = if (copied) "Kopyalandı" else "Yanıtı kopyala",
                                        tint = if (copied) colors.green else colors.ink.copy(alpha = 0.45f),
                                        modifier = Modifier.size(15.dp),
                                    )
                                    Spacer(Modifier.width(4.dp))
                                    Text(
                                        text = if (copied) "Kopyalandı" else "Kopyala",
                                        fontFamily = WiqoSans,
                                        fontSize = 12.sp,
                                        color = if (copied) colors.green else colors.ink.copy(alpha = 0.5f),
                                    )
                                }
                            }
                        }
                    }

                    if (state.sending) {
                        item(key = "sending-indicator") {
                            ThinkingLiveView(label = state.progress ?: "Bakıyorum…")
                        }
                    }
                    if (state.partialReply.isNotEmpty()) {
                        item(key = "partial-reply") {
                            MarkdownReply(text = state.partialReply)
                        }
                    }
                }
            }
        }

        // Quick suggestions row right above the composer (matching screenshot)
        if (state.messages.isEmpty() && !state.sending) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                quickSuggestions.forEach { suggestion ->
                    Row(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(colors.canvas)
                            .border(1.dp, colors.line, CircleShape)
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                onClick = {
                                    val textToSend = suggestion.title
                                    draft = ""
                                    keyboard?.hide()
                                    vm.send(textToSend)
                                },
                            )
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        if (suggestion.icon != null) {
                            Icon(
                                imageVector = suggestion.icon,
                                contentDescription = null,
                                tint = colors.ink.copy(alpha = 0.55f),
                                modifier = Modifier.size(15.dp),
                            )
                        }
                        Text(
                            text = suggestion.title,
                            fontFamily = WiqoSans,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium,
                            color = colors.ink,
                        )
                    }
                }
            }
        }

        // Floating Message Composer matching iOS CopilotView composer
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            val composerShape = RoundedCornerShape(26.dp)

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(composerShape)
                    .background(colors.inset)
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            ) {
                // Agent mode banner if active
                if (isCreatingAgent) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(bottom = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.PersonAdd, contentDescription = null, tint = colors.ink, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(text = "Ajan oluşturma modu", fontFamily = WiqoSans, fontSize = 12.sp, fontWeight = FontWeight.Medium, color = colors.ink)
                        }
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = "Kapat",
                            tint = colors.ink3,
                            modifier = Modifier
                                .size(18.dp)
                                .clickable { isCreatingAgent = false },
                        )
                    }
                }

                // Attachment preview strip
                if (attachments.isNotEmpty()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                            .padding(bottom = 6.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        attachments.forEachIndexed { index, att ->
                            Box(
                                modifier = Modifier
                                    .background(colors.surface, RoundedCornerShape(8.dp))
                                    .padding(horizontal = 8.dp, vertical = 4.dp),
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(text = att.name, fontFamily = WiqoSans, fontSize = 12.sp, color = colors.ink)
                                    Spacer(Modifier.width(4.dp))
                                    Icon(
                                        imageVector = Icons.Default.Close,
                                        contentDescription = "Kaldır",
                                        tint = colors.ink.copy(alpha = 0.5f),
                                        modifier = Modifier
                                            .size(14.dp)
                                            .clickable { attachments.removeAt(index) },
                                    )
                                }
                            }
                        }
                    }
                }

                // Input Row
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // "+" Menu button
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .clickable(
                                enabled = !state.sending,
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                onClick = { showPlusMenu = true },
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Default.Add,
                            contentDescription = "Ekle",
                            tint = colors.ink,
                            modifier = Modifier.size(24.dp),
                        )
                    }

                    Spacer(Modifier.width(4.dp))

                    // Text Field
                    BasicTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        modifier = Modifier
                            .weight(1f)
                            .padding(vertical = 10.dp)
                            .onFocusChanged { isComposerFocused = it.isFocused },
                        maxLines = 6,
                        cursorBrush = SolidColor(colors.signal),
                        textStyle = androidx.compose.ui.text.TextStyle(
                            fontFamily = WiqoSans,
                            fontSize = 16.sp,
                            color = colors.ink,
                        ),
                        decorationBox = { inner ->
                            if (draft.isEmpty()) {
                                Text(
                                    text = if (isRecordingAudio) "Dinliyorum…" else if (isCreatingAgent) "Ajanın ne yapsın?" else "Wiqo'ya anlat",
                                    fontFamily = WiqoSans,
                                    fontSize = 16.sp,
                                    color = colors.ink3,
                                )
                            }
                            inner()
                        },
                    )

                    Spacer(Modifier.width(4.dp))

                    // Trailing 34x34 action button matching iOS trailingComposerButton
                    if (state.sending) {
                        Box(
                            modifier = Modifier
                                .size(34.dp)
                                .clip(CircleShape)
                                .background(colors.ink)
                                .clickable { vm.cancelSending() },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Default.Stop,
                                contentDescription = "Durdur",
                                tint = colors.systemBackground,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    } else if (canSend && !isRecordingAudio) {
                        Box(
                            modifier = Modifier
                                .size(34.dp)
                                .clip(CircleShape)
                                .background(colors.ink)
                                .clickable {
                                    val textToSend = draft
                                    val attToSend = attachments.toList()
                                    draft = ""
                                    attachments.clear()
                                    keyboard?.hide()
                                    vm.send(textToSend, attToSend)
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Default.ArrowUpward,
                                contentDescription = "Gönder",
                                tint = colors.systemBackground,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    } else {
                        Box(
                            modifier = Modifier
                                .size(34.dp)
                                .clip(CircleShape)
                                .background(colors.line.copy(alpha = 0.5f))
                                .clickable {
                                    if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                                        startSpeechInput()
                                    } else {
                                        audioPermission.launch(Manifest.permission.RECORD_AUDIO)
                                    }
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = if (isRecordingAudio) Icons.Default.Stop else Icons.Default.Mic,
                                contentDescription = if (isRecordingAudio) "Durdur" else "Ses kaydı",
                                tint = if (isRecordingAudio) colors.red else colors.ink,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
            }
        }

        // Modern Attachment Bottom Sheet replacing old DropdownMenu
        if (showPlusMenu) {
            val plusSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
            ModalBottomSheet(
                onDismissRequest = { showPlusMenu = false },
                sheetState = plusSheetState,
                containerColor = colors.surface,
                shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp)
                        .padding(bottom = 36.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        text = "Paylaş veya Ekle",
                        fontFamily = WiqoSans,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.ink,
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp),
                    )

                    AttachmentOptionTile(
                        title = "Fotoğraf",
                        subtitle = "Galeriden görsel seç veya ekle",
                        icon = Icons.Outlined.Image,
                        onClick = {
                            showPlusMenu = false
                            photoPicker.launch("image/*")
                        },
                    )

                    AttachmentOptionTile(
                        title = "Dosya",
                        subtitle = "Cihazındaki belgelere göz at",
                        icon = Icons.Outlined.Description,
                        onClick = {
                            showPlusMenu = false
                            filePicker.launch(arrayOf("*/*"))
                        },
                    )

                    AttachmentOptionTile(
                        title = "Belge tara",
                        subtitle = "Kamera ile otomatik tara",
                        icon = Icons.Outlined.DocumentScanner,
                        onClick = {
                            showPlusMenu = false
                            val activity = context as? Activity ?: return@AttachmentOptionTile
                            documentScanner.getStartScanIntent(activity)
                                .addOnSuccessListener { sender -> scanLauncher.launch(IntentSenderRequest.Builder(sender).build()) }
                        },
                    )

                    HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp), color = colors.separator)

                    AttachmentOptionTile(
                        title = "Ajan oluştur",
                        subtitle = "Özel akıllı görev yardımcısı tanımla",
                        icon = Icons.Outlined.PersonAdd,
                        onClick = {
                            showPlusMenu = false
                            isCreatingAgent = true
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun AttachmentOptionTile(
    title: String,
    subtitle: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onClick: () -> Unit,
) {
    val colors = WiqoDesign.colors
    val interactionSource = remember { MutableInteractionSource() }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(colors.canvas)
            .border(1.dp, colors.line.copy(alpha = 0.5f), RoundedCornerShape(14.dp))
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            )
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(colors.inset),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = colors.ink,
                modifier = Modifier.size(20.dp),
            )
        }

        Spacer(Modifier.width(14.dp))

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                fontFamily = WiqoSans,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                color = colors.ink,
            )
            Text(
                text = subtitle,
                fontFamily = WiqoSans,
                fontSize = 13.sp,
                color = colors.ink3,
            )
        }

        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.ink.copy(alpha = 0.25f),
            modifier = Modifier.size(16.dp),
        )
    }
}

