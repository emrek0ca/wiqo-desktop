package com.wiqo.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.wiqo.android.AppContainer
import com.wiqo.android.data.local.LocalConversationMessage
import com.wiqo.android.data.network.ApiException
import com.wiqo.android.data.network.ChatTurn
import com.wiqo.android.data.attachments.ChatAttachment
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import java.util.UUID

data class ChatUiState(
    val messages: List<LocalConversationMessage> = emptyList(),
    val progress: String? = null,
    val partialReply: String = "",
    val sending: Boolean = false,
    val error: String? = null,
    val completedSends: Int = 0,
)

class ChatViewModel(private val container: AppContainer, val conversationId: String = "default") : ViewModel() {
    private val mutableState = MutableStateFlow(ChatUiState())
    val state = mutableState.asStateFlow()
    private var accountId: String? = null

    init {
        viewModelScope.launch {
            accountId = container.api.currentAccountId()
            val account = accountId ?: return@launch
            if (conversationId != "default" && container.database.conversations().getMessages(account, conversationId).isEmpty()) {
                runCatching { container.api.conversationMessages(conversationId) }.getOrDefault(emptyList()).forEachIndexed { index, remote ->
                    val role = remote["role"]?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content } ?: return@forEachIndexed
                    val content = remote["content"]?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content } ?: return@forEachIndexed
                    val time = remote["createdAt"]?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }
                        ?.let(::parseRemoteTime) ?: (index + 1L)
                    container.database.conversations().insert(
                        LocalConversationMessage(
                            "remote-$conversationId-$index", account, conversationId, role, content, time,
                            (remote["artifacts"] as? kotlinx.serialization.json.JsonArray)?.let { artifacts ->
                                buildJsonObject { put("artifacts", artifacts) }.toString()
                            },
                        ),
                    )
                }
            }
            container.database.conversations().observe(account, conversationId).collectLatest { messages ->
                mutableState.value = mutableState.value.copy(messages = messages)
            }
        }
    }

    fun send(text: String, attachments: List<ChatAttachment> = emptyList()) {
        val clean = text.trim()
        val account = accountId ?: container.api.currentAccountId()
        if ((clean.isEmpty() && attachments.isEmpty()) || account == null || mutableState.value.sending) return
        accountId = account
        viewModelScope.launch {
            val requestText = clean.ifBlank { "Ekli dosyaları incele." }
            val displayText = clean.ifBlank { "Ekli dosyaları incele." }
            val attachmentMetadata = buildJsonObject {
                put("attachments", JsonArray(attachments.map { JsonPrimitive(it.name) }))
            }.toString().takeIf { attachments.isNotEmpty() }
            val userMessage = LocalConversationMessage(UUID.randomUUID().toString(), account, conversationId, "user", displayText, System.currentTimeMillis(), attachmentMetadata)
            container.database.conversations().insert(userMessage)
            mutableState.value = mutableState.value.copy(sending = true, error = null, progress = null, partialReply = "")
            try {
                val history = container.database.conversations().getMessages(account, conversationId)
                val turns = history.mapIndexed { index, message ->
                    val content = if (index == history.lastIndex) requestText else message.content
                    ChatTurn(message.role, content)
                }
                val response = container.api.converse(
                    conversationId,
                    turns,
                    attachments,
                    onProgress = { status -> mutableState.value = mutableState.value.copy(progress = status.ifBlank { null }) },
                    onDelta = { delta -> mutableState.value = mutableState.value.copy(partialReply = mutableState.value.partialReply + delta) },
                )
                container.database.conversations().insert(
                    LocalConversationMessage(
                        UUID.randomUUID().toString(), account, conversationId, "assistant", response.reply, System.currentTimeMillis(),
                        response.terminal?.safeDisplayMetadata()?.toString(),
                    ),
                )
                mutableState.value = mutableState.value.copy(sending = false, progress = null, partialReply = "", completedSends = mutableState.value.completedSends + 1)
            } catch (error: ApiException) {
                runCatching { container.database.conversations().delete(userMessage) }
                mutableState.value = mutableState.value.copy(sending = false, progress = null, partialReply = "", error = error.message)
            } catch (_: Exception) {
                runCatching { container.database.conversations().delete(userMessage) }
                mutableState.value = mutableState.value.copy(sending = false, progress = null, partialReply = "", error = "Yanıt alınamadı. Tekrar deneyebilirsin.")
            }
        }
    }

    fun dismissError() { mutableState.value = mutableState.value.copy(error = null) }

    private fun parseRemoteTime(value: String): Long = runCatching {
        java.time.LocalDateTime.parse(value, java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"))
            .toInstant(java.time.ZoneOffset.UTC).toEpochMilli()
    }.getOrDefault(0L)

    private fun JsonObject.safeDisplayMetadata(): JsonObject {
        val allowedKeys = setOf("artifacts", "executionState", "deferredTask", "projectTask", "agentTask", "replyIsProgress", "backendConfirmations")
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
