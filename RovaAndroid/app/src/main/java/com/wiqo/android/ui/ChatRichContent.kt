package com.wiqo.android.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.wiqo.android.data.artifacts.ChatArtifact
import com.wiqo.android.ui.theme.WiqoMono
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

internal data class ChatRelatedCard(val title: String, val route: String, val id: String?)
internal data class ChatConfirmationCard(val title: String, val summary: String)

internal data class ChatMessageMetadata(
    val attachmentNames: List<String> = emptyList(),
    val artifacts: List<ChatArtifact> = emptyList(),
    val related: ChatRelatedCard? = null,
    val confirmations: List<ChatConfirmationCard> = emptyList(),
)

internal fun parseMessageMetadata(raw: String?): ChatMessageMetadata {
    val root = runCatching { Json.parseToJsonElement(raw ?: "null").jsonObject }.getOrNull() ?: return ChatMessageMetadata()
    val attachmentNames = (root["attachments"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        .filter(String::isNotBlank).take(5)
    val artifacts = (root["artifacts"] as? JsonArray).orEmpty().mapNotNull { value ->
        val item = value as? JsonObject ?: return@mapNotNull null
        ChatArtifact(
            id = item.scalar("id") ?: return@mapNotNull null,
            filename = item.scalar("filename")?.take(120)?.ifBlank { "dosya" } ?: "dosya",
            mimeType = item.scalar("mimeType")?.take(120) ?: "application/octet-stream",
            sha256 = item.scalar("sha256") ?: return@mapNotNull null,
            downloadUrl = item.scalar("downloadURL") ?: return@mapNotNull null,
        )
    }.take(20)
    val project = root["projectTask"] as? JsonObject
    val agent = root["agentTask"] as? JsonObject
    val related = when {
        project != null -> ChatRelatedCard(
            title = "Proje: ${project.scalar("title") ?: "Wiqo çıktısı"}",
            route = "project-detail",
            id = project.scalar("id"),
        )
        agent != null -> ChatRelatedCard(
            title = "Ajan görevi: ${agent.scalar("title") ?: "Arka plan işi"}",
            route = "agent-task-detail",
            id = agent.scalar("id"),
        )
        root["deferredTask"] is JsonObject -> ChatRelatedCard("PC çevrimiçi olduğunda devam edecek", "activity", null)
        else -> null
    }
    val confirmations = (root["backendConfirmations"] as? JsonArray).orEmpty().mapNotNull { value ->
        val item = value as? JsonObject ?: return@mapNotNull null
        val title = item.scalar("title")?.take(120) ?: return@mapNotNull null
        ChatConfirmationCard(title, item.scalar("summary")?.take(400).orEmpty())
    }.take(10)
    return ChatMessageMetadata(attachmentNames, artifacts, related, confirmations)
}

@Composable
internal fun MarkdownReply(text: String) {
    val blocks = remember(text) { parseReplyBlocks(text) }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        blocks.forEach { block ->
            when (block) {
                is ReplyBlock.Paragraph -> Text(block.text, style = MaterialTheme.typography.bodyLarge)
                is ReplyBlock.Heading -> Text(
                    block.text,
                    style = if (block.level == 1) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                is ReplyBlock.Bullet -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(block.marker, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(block.text, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                }
                is ReplyBlock.Quote -> Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = RoundedCornerShape(4.dp)) {
                    Text(block.text, Modifier.fillMaxWidth().padding(12.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                is ReplyBlock.Rule -> androidx.compose.material3.HorizontalDivider()
                is ReplyBlock.Code -> Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                    shape = RoundedCornerShape(12.dp),
                ) {
                    Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (block.language.isNotBlank()) Text(block.language, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        SelectionContainer {
                            Text(
                                block.text,
                                Modifier.horizontalScroll(rememberScrollState()),
                                fontFamily = WiqoMono,
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                    }
                }
            }
        }
    }
}

private sealed interface ReplyBlock {
    data class Paragraph(val text: String) : ReplyBlock
    data class Heading(val level: Int, val text: String) : ReplyBlock
    data class Bullet(val marker: String, val text: String) : ReplyBlock
    data class Quote(val text: String) : ReplyBlock
    data class Code(val language: String, val text: String) : ReplyBlock
    data object Rule : ReplyBlock
}

private fun parseReplyBlocks(text: String): List<ReplyBlock> {
    val lines = text.replace("\r\n", "\n").split('\n')
    val result = mutableListOf<ReplyBlock>()
    val paragraph = mutableListOf<String>()
    var codeLanguage: String? = null
    val code = mutableListOf<String>()
    fun flushParagraph() {
        val value = paragraph.joinToString("\n").trim()
        if (value.isNotEmpty()) result += ReplyBlock.Paragraph(value)
        paragraph.clear()
    }
    lines.forEach { line ->
        val trimmed = line.trim()
        if (codeLanguage != null) {
            if (trimmed.startsWith("```")) {
                result += ReplyBlock.Code(codeLanguage.orEmpty(), code.joinToString("\n"))
                codeLanguage = null
                code.clear()
            } else code += line
            return@forEach
        }
        when {
            trimmed.startsWith("```") -> { flushParagraph(); codeLanguage = trimmed.drop(3).trim() }
            trimmed.isEmpty() -> flushParagraph()
            trimmed.startsWith("### ") -> { flushParagraph(); result += ReplyBlock.Heading(3, trimmed.drop(4)) }
            trimmed.startsWith("## ") -> { flushParagraph(); result += ReplyBlock.Heading(2, trimmed.drop(3)) }
            trimmed.startsWith("# ") -> { flushParagraph(); result += ReplyBlock.Heading(1, trimmed.drop(2)) }
            trimmed.startsWith("> ") -> { flushParagraph(); result += ReplyBlock.Quote(trimmed.drop(2)) }
            trimmed in setOf("---", "***", "___") -> { flushParagraph(); result += ReplyBlock.Rule }
            trimmed.startsWith("- ") || trimmed.startsWith("* ") || trimmed.startsWith("• ") -> {
                flushParagraph(); result += ReplyBlock.Bullet("•", trimmed.drop(2))
            }
            trimmed.matches(Regex("[0-9]{1,3}[.)]\\s+.*")) -> {
                flushParagraph()
                val marker = trimmed.takeWhile(Char::isDigit) + "."
                result += ReplyBlock.Bullet(marker, trimmed.dropWhile(Char::isDigit).drop(2))
            }
            else -> paragraph += line
        }
    }
    if (codeLanguage != null) result += ReplyBlock.Code(codeLanguage.orEmpty(), code.joinToString("\n"))
    flushParagraph()
    return result.ifEmpty { listOf(ReplyBlock.Paragraph(text)) }
}

private fun JsonObject.scalar(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotBlank)

private fun JsonArray?.orEmpty(): List<JsonElement> = this?.toList().orEmpty()
