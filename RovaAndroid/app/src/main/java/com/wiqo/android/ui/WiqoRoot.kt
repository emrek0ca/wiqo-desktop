package com.wiqo.android.ui

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.ui.NavDisplay
import com.wiqo.android.AppContainer
import com.wiqo.android.NotificationLink
import kotlinx.serialization.Serializable

@Serializable
private data class Destination(val id: String, val path: String? = null, val notice: String? = null) : NavKey

private data class MainItem(val id: String, val label: String, val icon: androidx.compose.ui.graphics.vector.ImageVector)

private val mainItems = listOf(
    MainItem("chat", "Sohbet", Icons.AutoMirrored.Filled.Chat),
    MainItem("devices", "PC", Icons.Filled.Devices),
    MainItem("activity", "Etkinlik", Icons.Filled.History),
    MainItem("settings", "Ayarlar", Icons.Filled.Settings),
)

@Composable
internal fun WiqoRoot(container: AppContainer, notificationLink: NotificationLink?, onNotificationConsumed: () -> Unit) {
    val authViewModel: AuthViewModel = viewModel(factory = remember(container) { AuthViewModel.Factory(container) })
    val auth by authViewModel.state.collectAsState()
    if (!auth.signedIn) {
        AuthScreen(state = auth, onLogin = authViewModel::login, onRegister = authViewModel::register,
            onResetRequest = authViewModel::requestReset, onReset = authViewModel::resetPassword)
    } else {
        MainNavigation(container, authViewModel::signOut, notificationLink, onNotificationConsumed)
    }
}

@Composable
private fun MainNavigation(
    container: AppContainer,
    onSignOut: () -> Unit,
    notificationLink: NotificationLink?,
    onNotificationConsumed: () -> Unit,
) {
    val backStack = rememberNavBackStack(Destination("chat"))
    val current = backStack.lastOrNull() as? Destination ?: Destination("chat")
    val isMain = current.id in mainItems.map(MainItem::id)
    androidx.compose.runtime.LaunchedEffect(notificationLink) {
        val link = notificationLink ?: return@LaunchedEffect
        val destination = when (link.route) {
            "connected" -> Destination("connected", java.util.UUID.randomUUID().toString(), link.oauthMessage)
            "chat" -> when {
                link.conversationId != null -> Destination("chat", link.conversationId)
                link.taskId != null -> Destination("task-request", link.taskId)
                else -> Destination("chat")
            }
            "tasks" -> Destination("tasks")
            "agent-tasks" -> Destination("agent-task-detail", link.agentTaskId)
            "devices" -> Destination("devices")
            else -> when {
                link.projectId != null -> Destination("project-detail", link.projectId)
                link.runId != null && link.automationId != null -> Destination("automation-run", "${link.automationId}/runs/${link.runId}/journal")
                else -> Destination("activity")
            }
        }
        backStack.clear()
        backStack.add(destination)
        onNotificationConsumed()
    }

    val destinations = remember(container, backStack) {
        entryProvider<NavKey> {
            entry<Destination> { destination ->
                when (destination.id) {
                    "chat" -> ChatScreen(
                        container = container,
                        conversationId = destination.path ?: "default",
                        onNewConversation = { backStack.add(Destination("chat", java.util.UUID.randomUUID().toString())) },
                        onOpenRelated = { id, path -> backStack.add(Destination(id, path)) },
                    )
                    "devices" -> DeviceScreen(container) { backStack.add(Destination("pairing")) }
                    "activity" -> RemotePage(container, DestinationData(destination.id, destination.path), title = "Etkinlik")
                    "settings" -> SettingsScreen(container.preferences, onNavigate = { next -> backStack.add(Destination(next.id, next.path)) }, onSignOut = onSignOut)
                    "history" -> RemotePage(
                        container,
                        DestinationData(destination.id, destination.path),
                        title = "Sohbet geçmişi",
                        onSelect = { conversationId -> backStack.add(Destination("chat", conversationId)) },
                    )
                    "subscription" -> SubscriptionScreen(container)
                    "pairing" -> PairingScreen(container) { if (backStack.size > 1) backStack.removeAt(backStack.lastIndex) }
                    "profile" -> RemotePage(container, DestinationData(destination.id, destination.path, destination.notice), title = "Hesap")
                    else -> RemotePage(container, DestinationData(destination.id, destination.path, destination.notice), title = destinationTitle(destination.id))
                }
            }
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val expanded = maxWidth >= 600.dp
        if (expanded) {
            Row(Modifier.fillMaxSize()) {
                NavigationRail {
                    Spacer(Modifier.width(4.dp))
                    mainItems.forEach { item ->
                        NavigationRailItem(
                            selected = current.id == item.id,
                            onClick = { selectRoot(backStack, item.id) },
                            icon = { androidx.compose.material3.Icon(item.icon, contentDescription = item.label) },
                            label = { androidx.compose.material3.Text(item.label) },
                        )
                    }
                }
                Column(Modifier.weight(1f).fillMaxSize()) {
                    NavDisplay(
                        backStack = backStack,
                        onBack = { if (backStack.size > 1) backStack.removeAt(backStack.lastIndex) },
                        entryProvider = destinations,
                    )
                }
            }
        } else {
            Scaffold(
                bottomBar = {
                    if (isMain) NavigationBar {
                        mainItems.forEach { item ->
                            NavigationBarItem(
                                selected = current.id == item.id,
                                onClick = { selectRoot(backStack, item.id) },
                                icon = { androidx.compose.material3.Icon(item.icon, contentDescription = item.label) },
                                label = { androidx.compose.material3.Text(item.label) },
                            )
                        }
                    }
                },
            ) { innerPadding ->
                NavDisplay(
                    modifier = Modifier.fillMaxSize().padding(innerPadding),
                    backStack = backStack,
                    onBack = { if (backStack.size > 1) backStack.removeAt(backStack.lastIndex) },
                    entryProvider = destinations,
                )
            }
        }
    }
}

private fun selectRoot(backStack: MutableList<NavKey>, id: String) {
    backStack.clear()
    backStack.add(Destination(id))
}

private fun destinationTitle(id: String): String = when (id) {
    "task-request" -> "Görev sonucu"
    "agent-task-detail" -> "Ajan görevi"
    "project-detail" -> "Proje"
    "automation-run" -> "Otomasyon ayrıntısı"
    "connected" -> "Bağlı hesaplar"
    "skills" -> "Beceriler"
    "agents" -> "Ajanlar"
    "agent-tasks" -> "Ajan görevleri"
    "memory" -> "Hafıza"
    "memory-candidates" -> "Hafıza önerileri"
    "trust" -> "Güven izinleri"
    "tasks" -> "Görevler"
    "goals" -> "Hedefler"
    "automations" -> "Otomasyonlar"
    "subscription" -> "Wiqo Pro"
    "invites" -> "Davetler"
    else -> "Wiqo"
}
