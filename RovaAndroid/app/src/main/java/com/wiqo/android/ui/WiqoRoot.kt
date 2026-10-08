package com.wiqo.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
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
import com.wiqo.android.AppContainer
import com.wiqo.android.NotificationLink
import com.wiqo.android.data.security.SecureTokenStore
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
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
    var conversationId by remember { mutableStateOf("default") }
    var draftPrompt by remember { mutableStateOf<String?>(null) }
    var showSidebar by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showPCSettings by remember { mutableStateOf(false) }
    var showTemplates by remember { mutableStateOf(false) }
    var showPairing by remember { mutableStateOf(false) }
    var showPaywall by remember { mutableStateOf(false) }
    var remoteDestination by remember { mutableStateOf<DestinationData?>(null) }
    var homeRefresh by remember { mutableStateOf(0) }
    var pcError by remember { mutableStateOf<String?>(null) }
    var pcNotice by remember { mutableStateOf<String?>(null) }

    var isPaired by remember { mutableStateOf(false) }
    var isConnected by remember { mutableStateOf(false) }
    var deviceName by remember { mutableStateOf("PC") }
    var userName by remember { mutableStateOf("Wiqo Kullanıcısı") }
    var userEmail by remember { mutableStateOf("") }

    val conversationList = remember { mutableStateListOf<ConversationItem>() }

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
            isPaired = pairedDevice != null && container.tokenStore.read(SecureTokenStore.PAIRING_TOKEN) != null
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
            "activity" -> remoteDestination = DestinationData("activity", null)
            "settings" -> showSettings = true
            "subscription" -> showPaywall = true
            "pairing" -> showPairing = true
            "connected" -> remoteDestination = DestinationData("connected", null, link.oauthMessage)
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
            onNewConversation = {
                draftPrompt = null
                conversationId = UUID.randomUUID().toString()
            },
            onOpenRelated = { route, id ->
                when (route) {
                    "project-detail", "agent-task-detail" -> remoteDestination = DestinationData(route, id)
                    "devices" -> showPCSettings = true
                    else -> remoteDestination = DestinationData("activity", null)
                }
            },
            onSendCompleted = { homeRefresh += 1 },
        )

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

        if (showSettings && remoteDestination == null && !showPaywall && !showPairing) {
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
            if (destination.id == "profile") ProfileScreen(
                container = container,
                onBack = { remoteDestination = null; homeRefresh += 1 },
                onDeleted = onSignOut,
                onSaved = { homeRefresh += 1 },
            ) else RemotePage(
                container = container,
                destination = destination,
                title = destination.id.replace('-', ' ').replaceFirstChar(Char::uppercase),
                onBack = { remoteDestination = null; homeRefresh += 1 },
                onPair = if (destination.id == "devices") ({ showPairing = true }) else null,
                onSelect = when (destination.id) {
                    "agent-tasks" -> ({ id -> remoteDestination = DestinationData("agent-task-detail", id) })
                    "automations" -> ({ id -> remoteDestination = DestinationData("automation-detail", id) })
                    else -> null
                },
            )
        }
    }
}
