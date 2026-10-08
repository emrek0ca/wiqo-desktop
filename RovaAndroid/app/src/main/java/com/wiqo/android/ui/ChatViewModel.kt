package com.wiqo.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.wiqo.android.AppContainer
import com.wiqo.android.data.local.LocalConversationMessage
import com.wiqo.android.data.network.ApiException
import com.wiqo.android.data.network.ChatTurn
import com.wiqo.android.data.attachments.ChatAttachment
import com.wiqo.android.data.attachments.ChatFileContent
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import java.util.UUID

data class ChatUiState(
    val messages: List<LocalConversationMessage> = emptyList(),
    val progress: String? = null,
    val partialReply: String = "",
    val sending: Boolean = false,
    val recovering: Boolean = false,
    val error: String? = null,
    val completedSends: Int = 0,
    val pendingConfirmations: List<JsonObject> = emptyList(),
    val confirmationBusy: String? = null,
    val locationRequestId: String? = null,
    val liveUpdates: List<String> = emptyList(),
)

class ChatViewModel(private val container: AppContainer, val conversationId: String = "default") : ViewModel() {
    private val mutableState = MutableStateFlow(ChatUiState())
    val state = mutableState.asStateFlow()
    private var accountId: String? = null

    init {
        viewModelScope.launch {
            accountId = container.api.currentAccountId()
            val account = accountId ?: return@launch
            if (conversationId != "default") {
                val local = container.database.conversations().getMessages(account, conversationId)
                val localCounts = local.groupingBy { it.role to it.content }.eachCount()
                val remoteCounts = mutableMapOf<Pair<String, String>, Int>()
                runCatching { container.api.conversationMessages(conversationId) }.getOrDefault(emptyList()).forEachIndexed { index, remote ->
                    val role = remote["role"]?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content } ?: return@forEachIndexed
                    val content = remote["content"]?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content } ?: return@forEachIndexed
                    val key = role to content
                    val count = (remoteCounts[key] ?: 0) + 1
                    remoteCounts[key] = count
                    if (count <= (localCounts[key] ?: 0)) return@forEachIndexed
                    val time = remote["createdAt"]?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }
                        ?.let(::parseRemoteTime) ?: (index + 1L)
                    container.database.conversations().insert(
                        LocalConversationMessage(
                            "remote-$conversationId-$index", account, conversationId, role, content, time,
                            buildJsonObject {
                                (remote["artifacts"] as? JsonArray)?.let { put("artifacts", it) }
                                (remote["widgets"] as? JsonArray)?.let { put("widgets", it) }
                            }.toString(),
                        ),
                    )
                }
            }
            container.database.conversations().observe(account, conversationId).collectLatest { messages ->
                mutableState.value = mutableState.value.copy(messages = messages)
            }
        }
    }

    private var sendJob: kotlinx.coroutines.Job? = null
    private var currentRequestId: String? = null

    fun cancelSending() {
        val requestId = currentRequestId ?: return
        if (sendJob?.isActive != true) return
        sendJob?.cancel()
        sendJob = null
        mutableState.value = mutableState.value.copy(sending = false, recovering = true, progress = "İşlem sunucuda sürüyor; yanıt izleniyor…", partialReply = "")
        viewModelScope.launch {
            try {
                val response = container.api.awaitCopilotRequest(requestId, conversationId,
                    onProgress = { status -> mutableState.value = mutableState.value.copy(progress = status) },
                    onEvent = ::handleStreamEvent)
                val account = accountId ?: return@launch
                container.database.conversations().insert(LocalConversationMessage(
                    UUID.randomUUID().toString(), account, conversationId, "assistant", response.reply,
                    System.currentTimeMillis(), response.terminal?.safeDisplayMetadata()?.toString(),
                ))
                mutableState.value = mutableState.value.copy(recovering = false, progress = null, partialReply = "",
                    pendingConfirmations = emptyList(), locationRequestId = null, completedSends = mutableState.value.completedSends + 1)
            } catch (failure: Exception) {
                mutableState.value = mutableState.value.copy(recovering = false, progress = null,
                    error = failure.message ?: "İşlem sonucu alınamadı. Sohbeti yeniden açıp geçmişi yenile.")
            } finally { currentRequestId = null }
        }
    }

    private val answeredLocationRequests = mutableSetOf<String>()

    fun send(text: String, attachments: List<ChatAttachment> = emptyList(), files: List<ChatFileContent> = emptyList(), createAgent: Boolean = false) {
        val clean = text.trim()
        val account = accountId ?: container.api.currentAccountId()
        if (account == null) {
            mutableState.value = mutableState.value.copy(error = "Oturumun sona erdi. Yeniden giriş yap.")
            return
        }
        if (clean.length > 4_000) {
            mutableState.value = mutableState.value.copy(error = "Mesaj en fazla 4.000 karakter olabilir.")
            return
        }
        if (attachments.size > 4) {
            mutableState.value = mutableState.value.copy(error = "Bir kerede en fazla dört görsel ekleyebilirsin.")
            return
        }
        if (files.size > 5 || JsonArray(files.map { it.toJson() }).toString().toByteArray(Charsets.UTF_8).size > 6_000_000) {
            mutableState.value = mutableState.value.copy(error = "Dosya içeriği sunucu sınırını aşıyor. Daha az dosya ekleyip tekrar dene.")
            return
        }
        if ((clean.isEmpty() && attachments.isEmpty() && files.isEmpty()) || mutableState.value.sending || mutableState.value.recovering) return
        accountId = account
        val requestId = UUID.randomUUID().toString()
        currentRequestId = requestId
        sendJob = viewModelScope.launch {
            val requestText = clean.ifBlank { "Ekli dosyaları incele." }
            val displayText = clean.ifBlank { "Ekli dosyaları incele." }
            val attachmentMetadata = buildJsonObject {
                put("attachments", JsonArray((attachments.map { it.name } + files.map { it.name }).map { JsonPrimitive(it) }))
            }.toString().takeIf { attachments.isNotEmpty() || files.isNotEmpty() }
            val userMessage = LocalConversationMessage(UUID.randomUUID().toString(), account, conversationId, "user", displayText, System.currentTimeMillis(), attachmentMetadata)
            container.database.conversations().insert(userMessage)
            mutableState.value = mutableState.value.copy(sending = true, error = null, progress = null, partialReply = "", pendingConfirmations = emptyList(), liveUpdates = emptyList())
            try {
                val history = container.database.conversations().getMessages(account, conversationId)
                val recent = history.takeLast(16)
                val turns = recent.mapIndexed { index, message ->
                    val content = if (index == recent.lastIndex) requestText else message.content
                    ChatTurn(message.role, content)
                }
                val response = container.api.converse(
                    conversationId,
                    turns,
                    requestId = requestId,
                    attachments,
                    files = files,
                    createAgent = createAgent,
                    onProgress = { status -> mutableState.value = mutableState.value.copy(progress = status.ifBlank { null }) },
                    onDelta = { delta -> mutableState.value = mutableState.value.copy(partialReply = mutableState.value.partialReply + delta) },
                    onEvent = ::handleStreamEvent,
                )
                container.database.conversations().insert(
                    LocalConversationMessage(
                        UUID.randomUUID().toString(), account, conversationId, "assistant", response.reply, System.currentTimeMillis(),
                        response.terminal?.safeDisplayMetadata()?.toString(),
                    ),
                )
                mutableState.value = mutableState.value.copy(sending = false, progress = null, partialReply = "", pendingConfirmations = emptyList(), locationRequestId = null, completedSends = mutableState.value.completedSends + 1)
                currentRequestId = null
            } catch (_: CancellationException) {
                // The backend may still finish; cancelSending follows the request ledger.
            } catch (error: ApiException) {
                runCatching { container.database.conversations().delete(userMessage) }
                mutableState.value = mutableState.value.copy(sending = false, progress = null, partialReply = "", error = error.message)
                currentRequestId = null
            } catch (_: Exception) {
                runCatching { container.database.conversations().delete(userMessage) }
                mutableState.value = mutableState.value.copy(sending = false, progress = null, partialReply = "", error = "Yanıt alınamadı. Tekrar deneyebilirsin.")
                currentRequestId = null
            }
        }
    }

    fun dismissError() { mutableState.value = mutableState.value.copy(error = null) }

    fun resolveConfirmation(confirmation: JsonObject, approved: Boolean) {
        val id = (confirmation["id"] as? JsonPrimitive)?.content ?: return
        if (mutableState.value.confirmationBusy != null) return
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(confirmationBusy = id, error = null)
            try {
                val details = confirmation["details"] as? JsonObject ?: JsonObject(emptyMap())
                val body = container.api.backendConfirmationBody(id, approved, details)
                container.api.post("copilot/confirm", body)
                mutableState.value = mutableState.value.copy(
                    confirmationBusy = null,
                    pendingConfirmations = mutableState.value.pendingConfirmations.filterNot { (it["id"] as? JsonPrimitive)?.content == id },
                )
            } catch (error: Exception) {
                mutableState.value = mutableState.value.copy(confirmationBusy = null, error = error.message ?: "Onay gönderilemedi.")
            }
        }
    }

    fun respondWithLocation(city: String?) {
        val id = mutableState.value.locationRequestId ?: return
        if (!answeredLocationRequests.add(id)) return
        viewModelScope.launch {
            try {
                container.api.post("copilot/requests/$id/location", buildJsonObject { put("city", city?.trim()?.takeIf(String::isNotBlank)?.let { JsonPrimitive(it) } ?: JsonNull) })
                mutableState.value = mutableState.value.copy(locationRequestId = null)
            } catch (error: Exception) {
                answeredLocationRequests.remove(id)
                mutableState.value = mutableState.value.copy(error = error.message ?: "Konum yanıtı gönderilemedi.")
            }
        }
    }

    private fun handleStreamEvent(event: JsonObject) {
        when ((event["type"] as? JsonPrimitive)?.content) {
            "confirmation_needed" -> {
                val confirmations = (event["backendConfirmations"] as? JsonArray)
                    ?.mapNotNull { it as? JsonObject }.orEmpty()
                mutableState.value = mutableState.value.copy(pendingConfirmations = confirmations)
            }
            "location_required" -> {
                val id = (event["requestId"] as? JsonPrimitive)?.content
                if (id != null && id !in answeredLocationRequests) {
                    mutableState.value = mutableState.value.copy(locationRequestId = id)
                }
            }
            "step_update", "activity" -> {
                val step = event["step"] as? JsonObject
                val activity = event["activity"] as? JsonObject
                val label = (step?.get("summary") ?: activity?.get("text") ?: activity?.get("message")) as? JsonPrimitive
                label?.content?.takeIf(String::isNotBlank)?.let { message ->
                    mutableState.value = mutableState.value.copy(liveUpdates = (mutableState.value.liveUpdates + message).takeLast(8))
                }
            }
        }
    }

    private fun parseRemoteTime(value: String): Long = runCatching {
        java.time.LocalDateTime.parse(value, java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"))
            .toInstant(java.time.ZoneOffset.UTC).toEpochMilli()
    }.getOrDefault(0L)

    private fun JsonObject.safeDisplayMetadata(): JsonObject {
        val allowedKeys = setOf("artifacts", "widgets", "executionState", "deferredTask", "projectTask", "agentTask", "replyIsProgress", "backendConfirmations")
        val safeConfirmations = (this["backendConfirmations"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { value ->
            val confirmation = value as? JsonObject ?: return@mapNotNull null
            val safeFields = setOf("id", "kind", "title", "summary", "requiresUserPresence", "expiresAt")
            JsonObject(confirmation.filterKeys(safeFields::contains))
        }?.let(::JsonArray)
        return JsonObject(filterKeys(allowedKeys::contains).toMutableMap().apply {
            if (safeConfirmations != null) put("backendConfirmations", safeConfirmations)
        })
    }

    class Factory(private val container: AppContainer, private val conversationId: String = "default") : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = ChatViewModel(container, conversationId) as T
    }
}
