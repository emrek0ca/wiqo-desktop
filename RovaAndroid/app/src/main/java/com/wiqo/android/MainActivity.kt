package com.wiqo.android

import android.os.Bundle
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import com.wiqo.android.ui.WiqoRoot
import com.wiqo.android.ui.theme.WiqoTheme

class MainActivity : ComponentActivity() {
    private var notificationLink by mutableStateOf<NotificationLink?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        captureNotification(intent)
        val container = (application as WiqoApplication).container
        setContent {
            val themeMode by container.preferences.themeMode.collectAsState(initial = com.wiqo.android.data.local.ThemeMode.SYSTEM)
            WiqoTheme(themeMode) {
                WiqoRoot(container, notificationLink) { notificationLink = null }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureNotification(intent)
    }

    private fun captureNotification(intent: Intent?) {
        if (intent?.action == Intent.ACTION_VIEW && intent.data?.scheme.equals("wiqo", ignoreCase = true) && intent.data?.host == "oauth-callback") {
            val data = intent.data ?: return
            val status = data.getQueryParameter("status")
            val provider = data.getQueryParameter("provider")?.takeIf { it in setOf("google", "notion") }
            val message = data.getQueryParameter("message")?.take(180)
            val result = when {
                status == "success" && provider != null -> "${provider.replaceFirstChar(Char::uppercase)} hesabı bağlandı."
                status == "error" -> message ?: "Hesap bağlantısı tamamlanamadı."
                else -> "Hesap bağlantısı sonucu doğrulanamadı."
            }
            notificationLink = NotificationLink(route = "connected", oauthMessage = result)
            return
        }
        if (intent?.action != "OPEN_WIQO") return
        notificationLink = NotificationLink(
            route = intent.getStringExtra("route") ?: "activity",
            conversationId = intent.getStringExtra("conversationId"),
            confirmationId = intent.getStringExtra("confirmationId"),
            taskId = intent.getStringExtra("taskId") ?: intent.getStringExtra("requestId"),
            projectId = intent.getStringExtra("projectId"),
            runId = intent.getStringExtra("runId"),
            automationId = intent.getStringExtra("automationId"),
            agentTaskId = intent.getStringExtra("agentTaskId"),
            oauthMessage = null,
        )
    }
}

internal data class NotificationLink(
    val route: String,
    val conversationId: String? = null,
    val confirmationId: String? = null,
    val taskId: String? = null,
    val projectId: String? = null,
    val runId: String? = null,
    val automationId: String? = null,
    val agentTaskId: String? = null,
    val oauthMessage: String? = null,
)
