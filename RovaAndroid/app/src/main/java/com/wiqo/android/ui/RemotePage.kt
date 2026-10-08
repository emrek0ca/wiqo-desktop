package com.wiqo.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.wiqo.android.AppContainer
import com.wiqo.android.data.network.ApiException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

data class RemotePageState(
    val loading: Boolean = true,
    val data: JsonElement? = null,
    val error: String? = null,
    val busyAction: String? = null,
    val notice: String? = null,
    val openUrl: String? = null,
    val commandResult: JsonElement? = null,
    val providers: List<JsonObject> = emptyList(),
)

class RemotePageViewModel(private val container: AppContainer, private val path: String) : ViewModel() {
    private val mutableState = MutableStateFlow(RemotePageState())
    val state = mutableState.asStateFlow()

    init {
        refresh()
        if (path == "oauth") refreshProviders()
    }

    private fun refreshProviders() {
        viewModelScope.launch {
            val root = runCatching { container.api.get("oauth/providers") as? JsonObject }.getOrNull()
            val providers = (root?.get("providers") as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            mutableState.value = mutableState.value.copy(providers = providers)
        }
    }

    fun refresh() {
        if (mutableState.value.loading && mutableState.value.data != null) return
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(loading = true, error = null, notice = null)
            try {
                mutableState.value = mutableState.value.copy(loading = false, data = container.api.get(path), error = null)
            } catch (error: ApiException) {
                mutableState.value = mutableState.value.copy(loading = false, error = error.message ?: "İstek tamamlanamadı.")
            } catch (_: Exception) {
                mutableState.value = mutableState.value.copy(loading = false, error = "Bağlantı kurulamadı. Tekrar deneyebilirsin.")
            }
        }
    }

    internal fun perform(action: RemoteAction) {
        if (mutableState.value.busyAction != null) return
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(busyAction = action.label, error = null, notice = null)
            try {
                val commandResult = when (action.method) {
                    "POST" -> container.api.post(action.path, action.body)
                    "PUT" -> container.api.put(action.path, action.body)
                    "DELETE" -> container.api.delete(action.path)
                    "COMMAND" -> container.api.sendCompanionStatus(action.path)
                    else -> throw ApiException("Bu işlem desteklenmiyor.", 400)
                }
                if (action.path.startsWith("automations/")) runCatching { container.reminders.reconcile() }
                mutableState.value = mutableState.value.copy(
                    busyAction = null,
                    notice = action.successMessage,
                    commandResult = commandResult.takeIf { action.method == "COMMAND" },
                )
                val updated = container.api.get(path)
                mutableState.value = mutableState.value.copy(loading = false, data = updated)
            } catch (error: ApiException) {
                mutableState.value = mutableState.value.copy(busyAction = null, error = error.message ?: "İşlem tamamlanamadı.")
            } catch (_: Exception) {
                mutableState.value = mutableState.value.copy(busyAction = null, error = "İşlem tamamlanamadı. Tekrar deneyebilirsin.")
            }
        }
    }

    fun startOAuth(provider: String) {
        if (mutableState.value.busyAction != null) return
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(busyAction = provider, error = null, notice = null)
            try {
                val response = container.api.get("oauth/$provider/start") as? JsonObject
                val url = response?.get("url")?.let { (it as? JsonPrimitive)?.content }
                if (url.isNullOrBlank() || !url.startsWith("https://")) throw ApiException("Sağlayıcı bağlantısı açılamadı.", 502)
                mutableState.value = mutableState.value.copy(busyAction = null, openUrl = url)
            } catch (error: ApiException) {
                mutableState.value = mutableState.value.copy(busyAction = null, error = error.message ?: "Sağlayıcı bağlantısı açılamadı.")
            } catch (_: Exception) {
                mutableState.value = mutableState.value.copy(busyAction = null, error = "Sağlayıcı bağlantısı açılamadı.")
            }
        }
    }

    fun consumeOpenUrl() { mutableState.value = mutableState.value.copy(openUrl = null) }

    fun startTelegramLink() {
        if (mutableState.value.busyAction != null) return
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(busyAction = "telegram", error = null)
            try {
                val response = container.api.post("channels/telegram/link-code", JsonObject(emptyMap())) as? JsonObject
                val url = (response?.get("url") as? JsonPrimitive)?.content
                if (url == null || !url.startsWith("https://t.me/")) throw ApiException("Telegram bağlantısı açılamadı.", 502)
                mutableState.value = mutableState.value.copy(busyAction = null, openUrl = url)
            } catch (error: Exception) {
                mutableState.value = mutableState.value.copy(busyAction = null, error = error.message ?: "Telegram bağlantısı açılamadı.")
            }
        }
    }

    class Factory(private val container: AppContainer, private val path: String) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = RemotePageViewModel(container, path) as T
    }
}

internal data class RemoteAction(
    val label: String,
    val path: String,
    val method: String,
    val body: JsonObject = JsonObject(emptyMap()),
    val needsConfirmation: Boolean = false,
    val successMessage: String = "Değişiklik kaydedildi.",
)

internal fun endpointFor(destination: DestinationData): String = when (destination.id) {
    "activity" -> "activity"
    "history" -> "conversations"
    "profile" -> "profile"
    "connected" -> "oauth"
    "mcp" -> "mcp/servers"
    "channels" -> "channels"
    "skills" -> "skills"
    "agents" -> "agents"
    "agent-tasks" -> "agent-tasks"
    "agent-task-detail" -> "agent-tasks/${destination.path.asSafeIdentifier()}"
    "task-request" -> "copilot/requests/${destination.path.asSafeIdentifier()}"
    "project-detail" -> "projects/${destination.path.asNumericIdentifier()}"
    "automation-detail" -> "automations"
    "automation-runs" -> "automations/${destination.path.asNumericIdentifier()}/runs"
    "automation-run" -> {
        val path = destination.path.orEmpty()
        if (path.matches(Regex("[0-9]+/runs/[0-9]+/journal"))) "automations/$path" else "activity"
    }
    "memory" -> "memory/items"
    "memory-candidates" -> "memory/candidates"
    "trust" -> "trust-grants"
    "tasks" -> "tasks"
    "goals" -> "tasks/goals"
    "automations" -> "automations"
    "subscription" -> "billing/subscription"
    "invites" -> "auth/invite-codes"
    else -> destination.path ?: "profile"
}

internal data class DestinationData(val id: String, val path: String?, val notice: String? = null)

private fun String?.asSafeIdentifier(): String = this?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{1,120}")) } ?: "invalid"

private fun String?.asNumericIdentifier(): String = this?.takeIf { it.matches(Regex("[0-9]{1,18}")) } ?: "0"

internal fun JsonElement.visibleItems(): List<JsonElement> {
    if (this is JsonArray) return this
    val root = this as? JsonObject ?: return listOf(this)
    val activityLists = listOf("needsAttention", "upcoming", "recent").mapNotNull { root[it] as? JsonArray }
    if (activityLists.isNotEmpty()) return activityLists.flatMap { it }
    return root.values.firstOrNull { it is JsonArray }?.let { it as JsonArray } ?: listOf(root)
}

internal fun JsonElement.displayTitle(): String {
    val obj = this as? JsonObject ?: return (this as? JsonPrimitive)?.content ?: "Wiqo"
    val keys = listOf("title", "name", "displayName", "prompt", "email", "label", "type")
    return keys.firstNotNullOfOrNull { key -> (obj[key] as? JsonPrimitive)?.content?.takeIf(String::isNotBlank) }
        ?: "Wiqo"
}

internal fun JsonElement.itemIdentifier(): String? {
    val obj = this as? JsonObject ?: return null
    return listOf("id", "conversationId", "conversation_id").firstNotNullOfOrNull { key ->
        (obj[key] as? JsonPrimitive)?.content?.takeIf(String::isNotBlank)
    }
}

internal fun JsonElement.confirmation(): JsonObject? = (this as? JsonObject)?.get("confirmation") as? JsonObject

internal fun JsonElement.displayDetails(): List<Pair<String, String>> {
    val obj = this as? JsonObject ?: return emptyList()
    val hidden = setOf("token", "secret", "password", "signedTransaction", "dataBase64", "privateKey", "refreshToken")
    return obj.entries.mapNotNull { (key, value) ->
        if (key in hidden || key.equals("id", ignoreCase = true)) return@mapNotNull null
        val scalar = (value as? JsonPrimitive)?.content?.takeIf(String::isNotBlank) ?: return@mapNotNull null
        key to scalar
    }.take(4)
}

internal fun remoteActions(pageId: String, item: JsonElement): List<RemoteAction> {
    if (pageId == "connected") {
        val provider = item.value("provider")?.takeIf { it in setOf("google", "notion") } ?: return emptyList()
        val access = item.value("accessLevel")
        return buildList {
            if (access != "read") add(RemoteAction("Okuma izni", "oauth/$provider/access", "PUT", buildJsonObject { put("accessLevel", "read") }, successMessage = "Erişim düzeyi güncellendi."))
            if (access != "write") add(RemoteAction("Yazma izni", "oauth/$provider/access", "PUT", buildJsonObject { put("accessLevel", "write") }, needsConfirmation = true, successMessage = "Erişim düzeyi güncellendi."))
            add(RemoteAction("Bağlantıyı kaldır", "oauth/$provider", "DELETE", needsConfirmation = true, successMessage = "Hesap bağlantısı kaldırıldı."))
        }
    }
    val id = item.itemIdentifier() ?: return emptyList()
    val encodedId = java.net.URLEncoder.encode(id, Charsets.UTF_8.name())
    val basePath = when (pageId) {
        "memory" -> "memory/items"
        "memory-candidates" -> "memory/candidates"
        "trust" -> "trust-grants"
        "mcp" -> "mcp/servers"
        "automation-detail" -> "automations"
        "agent-task-detail" -> "agent-tasks"
        else -> pageId
    }
    fun action(
        label: String,
        suffix: String,
        method: String,
        confirm: Boolean = false,
        success: String = "Değişiklik kaydedildi.",
        body: JsonObject = JsonObject(emptyMap()),
    ) = RemoteAction(label, "$basePath/$encodedId$suffix", method, body, confirm, success)

    return when (pageId) {
        "devices" -> buildList {
            if (item.value("online") == "true") add(RemoteAction("Bilgisayar durumunu oku", id, "COMMAND", successMessage = "PC durumu güncellendi."))
            add(action("Bu hesaptan kaldır", "", "DELETE", confirm = true, success = "Bilgisayar hesaptan kaldırıldı."))
        }
        "skills" -> listOf(action("Beceriyi sil", "", "DELETE", confirm = true, success = "Beceri silindi."))
        "agents" -> buildList {
            add(action("Ajan hafızasını temizle", "/forget", "POST", confirm = true, success = "Ajan hafızası temizlendi."))
            if (item.value("isPrimary") != "true") add(action("Ajanı kaldır", "", "DELETE", confirm = true, success = "Ajan kaldırıldı."))
        }
        "mcp" -> listOf(action("Sunucuyu kaldır", "", "DELETE", confirm = true, success = "MCP sunucusu kaldırıldı."))
        "channels" -> listOf(action("Bağlantıyı kaldır", "", "DELETE", confirm = true, success = "Kanal bağlantısı kaldırıldı."))
        "memory-candidates" -> listOf(
            action("Kabul et", "/accept", "POST", success = "Hafıza kaydedildi."),
            action("Reddet", "/dismiss", "POST", confirm = true, success = "Öneri kaldırıldı."),
        )
        "memory" -> listOf(action("Sil", "", "DELETE", confirm = true, success = "Hafıza kaydı silindi."))
        "trust" -> listOf(action("İzni kaldır", "", "DELETE", confirm = true, success = "İzin kaldırıldı."))
        "tasks" -> if (item.value("status") == "done") emptyList() else listOf(
            action("Tamamlandı olarak işaretle", "/complete", "POST", success = "Görev tamamlandı."),
        )
        "agent-tasks" -> if (item.value("status") in setOf("done", "failed", "cancelled")) emptyList() else listOf(
            action("Görevi durdur", "/cancel", "POST", confirm = true, success = "Görev durduruldu."),
        )
        "agent-task-detail" -> if (item.value("status") in setOf("done", "failed", "cancelled")) emptyList() else listOf(
            action("Görevi durdur", "/cancel", "POST", confirm = true, success = "Görev durduruldu."),
        )
        "automations", "automation-detail" -> {
            val active = item.value("isActive") == "true" || item.value("lifecycleStatus") == "active"
            listOf(
                action(if (active) "Duraklat" else "Sürdür", if (active) "/pause" else "/resume", "POST", success = if (active) "Otomasyon duraklatıldı." else "Otomasyon sürdürüldü."),
                action("Şimdi çalıştır", "/run-now", "POST", confirm = true, success = "Otomasyon başlatıldı."),
                action("Otomasyonu sil", "", "DELETE", confirm = true, success = "Otomasyon silindi."),
            )
        }
        else -> emptyList()
    }
}

private fun JsonElement.value(key: String): String? =
    ((this as? JsonObject)?.get(key) as? JsonPrimitive)?.content
