package com.wiqo.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.wiqo.android.AppContainer
import com.wiqo.android.NotificationLink
import com.wiqo.android.data.security.SecureTokenStore
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import java.util.UUID

@Composable
internal fun WiqoRoot(
    container: AppContainer,
    notificationLink: NotificationLink?,
    onNotificationConsumed: () -> Unit,
) {
    val authViewModel: AuthViewModel = viewModel(factory = remember(container) { AuthViewModel.Factory(container) })
    val auth by authViewModel.state.collectAsState()

    if (!auth.signedIn) {
        AuthScreen(
            state = auth,
            onLogin = authViewModel::login,
            onRegister = authViewModel::register,
            onResetRequest = authViewModel::requestReset,
            onReset = authViewModel::resetPassword,
        )
    } else {
        WiqoHome(
            container = container,
            onSignOut = authViewModel::signOut,
            notificationLink = notificationLink,
            onNotificationConsumed = onNotificationConsumed,
        )
    }
}

@Composable
private fun WiqoHome(
    container: AppContainer,
    onSignOut: () -> Unit,
    notificationLink: NotificationLink?,
    onNotificationConsumed: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val lifecycleOwner = LocalLifecycleOwner.current
    var conversationId by remember { mutableStateOf("default") }
    var draftPrompt by remember { mutableStateOf<String?>(null) }
    var showSidebar by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showPCSettings by remember { mutableStateOf(false) }
    var showTemplates by remember { mutableStateOf(false) }
    var showPairing by remember { mutableStateOf(false) }
    var showPaywall by remember { mutableStateOf(false) }
    var showAct by remember { mutableStateOf(false) }
    var actProjectId by remember { mutableStateOf<String?>(null) }
    var actInitialRequest by remember { mutableStateOf<String?>(null) }
    var remoteDestination by remember { mutableStateOf<DestinationData?>(null) }
    val remoteBackStack = remember { mutableStateListOf<DestinationData>() }
    var homeRefresh by remember { mutableStateOf(0) }
    var pcError by remember { mutableStateOf<String?>(null) }
    var pcNotice by remember { mutableStateOf<String?>(null) }

    var isPaired by remember { mutableStateOf(false) }
    var isConnected by remember { mutableStateOf(false) }
    var deviceName by remember { mutableStateOf("PC") }
    var userName by remember { mutableStateOf("Wiqo Kullanıcısı") }
    var userEmail by remember { mutableStateOf("") }

    val conversationList = remember { mutableStateListOf<ConversationItem>() }

    DisposableEffect(lifecycleOwner, container) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) scope.launch { runCatching { container.reminders.reconcile() } }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    fun executePcCommand(type: String, value: Int? = null) {
        val deviceId = container.tokenStore.read(SecureTokenStore.COMPANION_DEVICE_ID)
        if (deviceId == null) {
            pcError = "Önce PC eşleştir."
            return
        }
        pcError = null
        pcNotice = null
        scope.launch {
            try {
                container.api.sendCompanionCommand(deviceId, type, value)
                pcNotice = "PC işlemi tamamlandı."
                homeRefresh += 1
            } catch (error: Exception) {
                pcError = error.message ?: "PC işlemi tamamlanamadı."
            }
        }
    }

    LaunchedEffect(homeRefresh) {
        runCatching { container.reminders.reconcile() }
        val profile = runCatching { container.api.get("profile") as? JsonObject }.getOrNull()
        userName = (profile?.get("displayName") as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotBlank) ?: "Wiqo Kullanıcısı"
        userEmail = (profile?.get("email") as? JsonPrimitive)?.contentOrNull.orEmpty()

        val deviceList = runCatching {
            ((container.api.get("devices") as? JsonObject)?.get("devices") as? JsonArray).orEmpty()
        }.getOrNull()
        if (deviceList != null) {
            val pairedId = container.tokenStore.read(SecureTokenStore.COMPANION_DEVICE_ID)
            val pairedDevice = deviceList.mapNotNull { it as? JsonObject }
                .firstOrNull { (it["id"] as? JsonPrimitive)?.contentOrNull == pairedId }
            isPaired = pairedId != null && container.tokenStore.read(SecureTokenStore.PAIRING_TOKEN) != null
            isConnected = isPaired && (pairedDevice?.get("online") as? JsonPrimitive)?.contentOrNull == "true"
            deviceName = (pairedDevice?.get("displayName") as? JsonPrimitive)?.contentOrNull ?: "PC"
        }

        val conversations = runCatching {
            ((container.api.get("conversations") as? JsonObject)?.get("conversations") as? JsonArray).orEmpty()
        }.getOrNull()
        if (conversations != null) {
            conversationList.clear()
            conversationList.addAll(conversations.mapNotNull { item ->
                val obj = item as? JsonObject ?: return@mapNotNull null
                val id = (obj["id"] as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
                val title = (obj["title"] as? JsonPrimitive)?.contentOrNull ?: "Sohbet"
                ConversationItem(id = id, title = title, updatedAt = System.currentTimeMillis())
            })
        }
    }

    LaunchedEffect(container) {
        var retryDelay = 2_000L
        while (isActive) {
            try {
                container.api.observeDeviceEvents { event ->
                    val device = event["device"] as? JsonObject ?: return@observeDeviceEvents
                    val id = (device["id"] as? JsonPrimitive)?.contentOrNull
                    val pairedId = container.tokenStore.read(SecureTokenStore.COMPANION_DEVICE_ID)
                    if (id != null && id == pairedId) {
                        isPaired = container.tokenStore.read(SecureTokenStore.PAIRING_TOKEN) != null
                        isConnected = isPaired && (device["online"] as? JsonPrimitive)?.contentOrNull == "true"
                        deviceName = (device["displayName"] as? JsonPrimitive)?.contentOrNull ?: deviceName
                    }
                }
                retryDelay = 2_000L
            } catch (error: com.wiqo.android.data.network.ApiException) {
                if (error.statusCode == 401 || error.statusCode == 403) break
            } catch (_: Exception) { /* Network loss: reconnect while the signed-in screen is active. */ }
            delay(retryDelay)
            retryDelay = (retryDelay * 2).coerceAtMost(30_000L)
        }
    }

    // Handle deep links and notification routes matching iOS
    LaunchedEffect(notificationLink) {
        val link = notificationLink ?: return@LaunchedEffect
        when (link.route) {
            "chat" -> {
                if (link.conversationId != null) {
                    conversationId = link.conversationId
                }
            }
            "devices" -> showPCSettings = true
            "activity" -> remoteDestination = when {
                link.confirmationId != null -> DestinationData("activity", null)
                link.automationId?.matches(Regex("[0-9]{1,18}")) == true &&
                    link.runId?.matches(Regex("[0-9]{1,18}")) == true ->
                    DestinationData("automation-run", "${link.automationId}/runs/${link.runId}/journal")
                link.projectId?.matches(Regex("[0-9]{1,18}")) == true -> DestinationData("project-detail", link.projectId)
                link.agentTaskId?.matches(Regex("[0-9]{1,18}")) == true -> DestinationData("agent-task-detail", link.agentTaskId)
                else -> DestinationData("activity", null)
            }
            "settings" -> showSettings = true
            "subscription" -> showPaywall = true
            "pairing" -> showPairing = true
            "connected" -> remoteDestination = DestinationData("connected", null, link.oauthMessage)
            "agent-tasks" -> remoteDestination = link.agentTaskId?.takeIf { it.matches(Regex("[0-9]{1,18}")) }
                ?.let { DestinationData("agent-task-detail", it) } ?: DestinationData("agent-tasks", null)
            else -> {
                if (link.conversationId != null) conversationId = link.conversationId
                else remoteDestination = DestinationData("activity", null)
            }
        }
        onNotificationConsumed()
    }

    Box(modifier = Modifier.fillMaxSize()) {
        ChatScreen(
            container = container,
            conversationId = conversationId,
            draftPrompt = draftPrompt,
            isPaired = isPaired,
            isConnected = isConnected,
            onOpenSidebar = { homeRefresh += 1; showSidebar = true },
            onOpenPCSettings = { showPCSettings = true },
            onOpenTemplates = { showTemplates = true },
            onOpenAct = { actProjectId = null; actInitialRequest = null; showAct = true },
            onNewConversation = {
                draftPrompt = null
                conversationId = UUID.randomUUID().toString()
            },
            onOpenRelated = { route, id ->
                when (route) {
                    "inline-ask" -> { draftPrompt = id?.take(500); showAct = false }
                    "act" -> {
                        val handoff = runCatching { Json.parseToJsonElement(id.orEmpty()) as? JsonObject }.getOrNull()
                        actProjectId = (handoff?.get("projectId") as? JsonPrimitive)?.contentOrNull
                        actInitialRequest = (handoff?.get("request") as? JsonPrimitive)?.contentOrNull
                        showAct = true
                    }
                    "project-detail", "agent-task-detail", "automation-detail", "agents" -> remoteDestination = DestinationData(route, id)
                    "devices" -> showPCSettings = true
                    else -> remoteDestination = DestinationData("activity", null)
                }
            },
            onSendCompleted = { homeRefresh += 1 },
        )

        if (showAct && !showPairing && !showPaywall) {
            ActScreen(container = container, onBack = { showAct = false; actProjectId = null; actInitialRequest = null },
                initialProjectId = actProjectId, initialRequest = actInitialRequest)
        }

        // Slide-in Conversation Sidebar Drawer matching iOS SidebarOverlay
        SidebarOverlay(
            isOpen = showSidebar,
            onDismiss = { showSidebar = false },
            conversations = conversationList,
            currentConversationId = conversationId,
            onSelectConversation = { id ->
                conversationId = id
                draftPrompt = null
                showSidebar = false
            },
            onNewChat = {
                conversationId = UUID.randomUUID().toString()
                draftPrompt = null
                showSidebar = false
            },
            onDeleteConversation = { id ->
                conversationList.removeAll { it.id == id }
                if (conversationId == id) {
                    conversationId = UUID.randomUUID().toString()
                }
                scope.launch {
                    runCatching { container.api.delete("conversations/$id") }
                        .onFailure { homeRefresh += 1 }
                }
            },
            onOpenSettings = {
                showSidebar = false
                showSettings = true
            },
            userName = userName,
            userEmail = userEmail,
        )

        if (showPCSettings) {
            PCSettingsSheet(
                onDismiss = { showPCSettings = false },
                isPaired = isPaired,
                isConnected = isConnected,
                deviceName = deviceName,
                onOpenPairing = {
                    showPCSettings = false
                    showPairing = true
                },
                onForgetDevice = {
                    scope.launch {
                        try {
                            container.tokenStore.read(SecureTokenStore.COMPANION_DEVICE_ID)?.let { id ->
                                container.api.delete("devices/$id")
                            }
                            listOf(SecureTokenStore.PAIRING_TOKEN, SecureTokenStore.PAIRING_FINGERPRINT,
                                SecureTokenStore.PAIRING_DEVICE_ID, SecureTokenStore.COMPANION_DEVICE_ID)
                                .forEach(container.tokenStore::remove)
                            isPaired = false
                            isConnected = false
                            showPCSettings = false
                            homeRefresh += 1
                        } catch (error: Exception) {
                            pcError = error.message ?: "PC kaldırılamadı. Tekrar dene."
                        }
                    }
                },
                error = pcError,
                notice = pcNotice,
                onLockPC = { executePcCommand("lockMac") },
                onSleepPC = { executePcCommand("sleepMac") },
                onMutePC = { executePcCommand("toggleMute") },
                onDisplaySleepPC = { executePcCommand("displaySleep") },
                onVolumeChange = { executePcCommand("setVolume", (it * 100).toInt().coerceIn(0, 100)) },
                onBrightnessChange = { executePcCommand("setBrightness", (it * 100).toInt().coerceIn(0, 100)) },
            )
        }

        if (showTemplates) {
            AutomationTemplatesSheet(
                onDismiss = { showTemplates = false },
                onSelectPrompt = { prompt ->
                    draftPrompt = prompt
                    conversationId = UUID.randomUUID().toString()
                    showTemplates = false
                },
            )
        }

        if (showPairing) {
            PairingScreen(
                container = container,
                onBack = { showPairing = false },
                onPaired = { showPairing = false; homeRefresh += 1 },
            )
        }

        if (showPaywall) {
            SubscriptionScreen(container = container, onBack = { showPaywall = false })
        }

        if (showSettings && remoteDestination == null && !showPaywall && !showPairing && !showPCSettings) {
            SettingsScreen(
                preferences = container.preferences,
                onNavigate = { destination ->
                    when (destination.id) {
                        "devices" -> showPCSettings = true
                        "subscription" -> showPaywall = true
                        else -> remoteDestination = destination
                    }
                },
                onSignOut = onSignOut,
                onBack = { showSettings = false },
            )
        }

        remoteDestination?.takeUnless { showPairing || showPaywall }?.let { destination ->
            if (destination.id == "tasks") WorkHubScreen(
                container = container,
                onBack = { remoteDestination = null; homeRefresh += 1 },
                onOpenRelated = { route, id -> remoteBackStack.add(destination); remoteDestination = DestinationData(route, id) },
            ) else if (destination.id == "profile") ProfileScreen(
                container = container,
                onBack = { remoteDestination = null; homeRefresh += 1 },
                onDeleted = onSignOut,
                onSaved = { homeRefresh += 1 },
            ) else RemotePage(
                container = container,
                destination = destination,
                title = when (destination.id) {
                    "activity" -> "Etkinlik"
                    "history" -> "Sohbet geçmişi"
                    "connected" -> "Bağlı hesaplar"
                    "mcp" -> "MCP sunucuları"
                    "channels" -> "Mesajlaşma kanalları"
                    "skills" -> "Beceriler"
                    "agents" -> "Ajanlar"
                    "agent-tasks" -> "Ajan görevleri"
                    "agent-task-detail" -> "Ajan görevi"
                    "memory" -> "Hafıza"
                    "memory-candidates" -> "Hafıza önerileri"
                    "trust" -> "Güven izinleri"
                    "tasks" -> "Görevler"
                    "goals" -> "Hedefler"
                    "automations" -> "Otomasyonlar"
                    "automation-detail" -> "Otomasyon"
                    "automation-runs" -> "Çalıştırmalar"
                    "automation-run" -> "Çalıştırma günlüğü"
                    "project-detail" -> "Proje"
                    "invites" -> "Davetler"
                    else -> destination.id.replace('-', ' ').replaceFirstChar(Char::uppercase)
                },
                onBack = {
                    remoteDestination = if (remoteBackStack.isNotEmpty()) remoteBackStack.removeAt(remoteBackStack.lastIndex) else null
                    homeRefresh += 1
                },
                onPair = if (destination.id == "devices") ({ showPairing = true }) else null,
                onSelectPrompt = if (destination.id == "skills") ({ prompt ->
                    draftPrompt = prompt
                    conversationId = UUID.randomUUID().toString()
                    remoteDestination = null
                    remoteBackStack.clear()
                    showSettings = false
                }) else null,
                onSelect = when (destination.id) {
                    "agent-tasks" -> ({ id -> remoteBackStack.add(destination); remoteDestination = DestinationData("agent-task-detail", id) })
                    "automations" -> ({ id -> remoteBackStack.add(destination); remoteDestination = DestinationData("automation-detail", id) })
                    "automation-detail" -> ({ id -> remoteBackStack.add(destination); remoteDestination = DestinationData("automation-runs", id) })
                    "automation-runs" -> ({ id ->
                        remoteBackStack.add(destination)
                        remoteDestination = DestinationData("automation-run", "${destination.path}/runs/$id/journal")
                    })
                    else -> null
                },
            )
        }
    }
}
