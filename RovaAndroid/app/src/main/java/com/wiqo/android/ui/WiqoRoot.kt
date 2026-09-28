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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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

    // Modal sheet visibility states matching iOS WiqoHomeView
    var showSidebar by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showPCSettings by remember { mutableStateOf(false) }
    var showTemplates by remember { mutableStateOf(false) }
    var showPairing by remember { mutableStateOf(false) }
    var showPaywall by remember { mutableStateOf(false) }
    var showActivity by remember { mutableStateOf(false) }
    var showWelcome by remember { mutableStateOf(false) }

    var isPaired by remember { mutableStateOf(false) }
    var isConnected by remember { mutableStateOf(false) }
    var deviceName by remember { mutableStateOf("PC") }
    var userName by remember { mutableStateOf("Wiqo Kullanıcısı") }
    var userEmail by remember { mutableStateOf("") }

    val conversationList = remember { mutableStateListOf<ConversationItem>() }

    // Refresh conversations and status from API
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            runCatching {
                val profile = container.api.get("profile") as? JsonObject
                if (profile != null) {
                    val name = (profile["displayName"] as? JsonPrimitive)?.contentOrNull
                    val email = (profile["email"] as? JsonPrimitive)?.contentOrNull
                    withContext(Dispatchers.Main) {
                        if (!name.isNullOrBlank()) userName = name
                        if (!email.isNullOrBlank()) userEmail = email
                    }
                }

                val devices = container.api.get("devices") as? JsonArray
                if (devices != null && devices.isNotEmpty()) {
                    val firstDev = devices.firstOrNull() as? JsonObject
                    val devLabel = (firstDev?.get("name") as? JsonPrimitive)?.contentOrNull ?: "PC"
                    withContext(Dispatchers.Main) {
                        isPaired = true
                        isConnected = true
                        deviceName = devLabel
                    }
                }

                val convs = container.api.get("conversations") as? JsonArray
                if (convs != null) {
                    val items = convs.mapNotNull { item ->
                        val obj = item as? JsonObject ?: return@mapNotNull null
                        val id = (obj["id"] as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
                        val title = (obj["title"] as? JsonPrimitive)?.contentOrNull ?: "Sohbet"
                        ConversationItem(id = id, title = title, updatedAt = System.currentTimeMillis())
                    }
                    withContext(Dispatchers.Main) {
                        conversationList.clear()
                        conversationList.addAll(items)
                    }
                }
            }
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
            "activity" -> showActivity = true
            "settings" -> showSettings = true
            "subscription" -> showPaywall = true
            "pairing" -> showPairing = true
            else -> {
                if (link.conversationId != null) conversationId = link.conversationId
                else showActivity = true
            }
        }
        onNotificationConsumed()
    }

    Box(modifier = Modifier.fillMaxSize()) {
        // Primary Screen: ChatScreen matching CopilotView.swift
        ChatScreen(
            container = container,
            conversationId = conversationId,
            draftPrompt = draftPrompt,
            isPaired = isPaired,
            isConnected = isConnected,
            onOpenSidebar = { showSidebar = true },
            onOpenPCSettings = { showPCSettings = true },
            onOpenTemplates = { showTemplates = true },
            onNewConversation = {
                draftPrompt = null
                conversationId = UUID.randomUUID().toString()
            },
            onOpenRelated = { route, id ->
                when (route) {
                    "project-detail", "agent-task-detail" -> showActivity = true
                    "devices" -> showPCSettings = true
                    else -> showActivity = true
                }
            },
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
                }
            },
            onOpenSettings = {
                showSidebar = false
                showSettings = true
            },
            userName = userName,
            userEmail = userEmail,
        )

        // Modal Sheets matching iOS .sheet(...) presentations
        if (showSettings) {
            SettingsSheet(
                onDismiss = { showSettings = false },
                onOpenPC = {
                    showSettings = false
                    showPCSettings = true
                },
                onOpenActivity = {
                    showSettings = false
                    showActivity = true
                },
                onSignOut = onSignOut,
                isPaired = isPaired,
                deviceName = deviceName,
                userName = userName,
            )
        }

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
                    isPaired = false
                    isConnected = false
                    showPCSettings = false
                },
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
            PairingSheet(
                onDismiss = { showPairing = false },
                onStartQrScan = {},
                onPairWithCode = { code ->
                    isPaired = true
                    isConnected = true
                    showPairing = false
                },
            )
        }

        if (showPaywall) {
            PaywallSheet(
                onDismiss = { showPaywall = false },
                onSubscribePro = {},
            )
        }

        if (showActivity) {
            ActivitySheet(
                onDismiss = { showActivity = false },
            )
        }

        if (showWelcome) {
            WiqoWelcomeSheet(
                onDismiss = { showWelcome = false },
                onConnect = {
                    showWelcome = false
                    showPairing = true
                },
            )
        }
    }
}
