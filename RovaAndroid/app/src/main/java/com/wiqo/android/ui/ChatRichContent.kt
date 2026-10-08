package com.wiqo.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wiqo.android.data.artifacts.ChatArtifact
import com.wiqo.android.ui.components.WiqoCodeBlock
import com.wiqo.android.ui.theme.WiqoDesign
import com.wiqo.android.ui.theme.WiqoMono
import com.wiqo.android.ui.theme.WiqoSans
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
    val widgets: List<JsonObject> = emptyList(),
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
    val widgets = (root["widgets"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }.take(20)
    return ChatMessageMetadata(attachmentNames, artifacts, widgets, related, confirmations)
}

@Composable
internal fun ChatWidgetSummary(widget: JsonObject, onOpenRelated: (String, String?) -> Unit) {
    val type = widget.scalar("type") ?: return
    val title = widget.scalar("title") ?: when (type) {
        "weather" -> "Hava durumu"
        "sources" -> "Kaynaklar"
        "artifact" -> "Dosya"
        else -> type.replace('_', ' ')
    }
    val summary = widget.scalar("summary") ?: widget.scalar("description")
    val colors = WiqoDesign.colors
    Column(Modifier.fillMaxWidth().background(colors.inset, RoundedCornerShape(12.dp)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Text(title, fontFamily = WiqoSans, fontWeight = FontWeight.SemiBold, color = colors.ink)
        summary?.let { Text(it.take(600), fontFamily = WiqoSans, color = colors.ink, fontSize = 13.sp) }
        when (type) {
            "list" -> (widget["items"] as? JsonArray).orEmpty().take(12).forEach { item ->
                val row = item as? JsonObject ?: return@forEach
                Text("• ${row.scalar("title").orEmpty()} ${row.scalar("subtitle").orEmpty()}".trim().take(250),
                    fontFamily = WiqoSans, color = colors.ink, fontSize = 13.sp)
            }
            "table" -> {
                val columns = (widget["columns"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                if (columns.isNotEmpty()) Text(columns.joinToString("  |  ").take(250), fontFamily = WiqoMono, fontSize = 12.sp)
                (widget["rows"] as? JsonArray).orEmpty().take(12).forEach { row ->
                    val values = (row as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                    Text(values.joinToString("  |  ").take(250), fontFamily = WiqoMono, fontSize = 12.sp)
                }
            }
            "created_resource" -> {
                val resource = widget.scalar("resourceType")
                val id = widget.scalar("id")
                val route = when (resource) {
                    "agent" -> "agents"
                    "automation" -> "automation-detail"
                    else -> null
                }
                if (route != null && id != null) androidx.compose.material3.TextButton(onClick = { onOpenRelated(route, id) }) {
                    Text("Aç")
                }
            }
        }
    }
}

@Composable
internal fun MarkdownReply(text: String) {
    val colors = WiqoDesign.colors
    val blocks = remember(text) { parseReplyBlocks(text) }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        blocks.forEach { block ->
            when (block) {
                is ReplyBlock.Paragraph -> SelectionContainer {
                    Text(
                        text = block.text,
                        fontFamily = WiqoSans,
                        fontSize = 15.sp,
                        lineHeight = 22.sp,
                        color = colors.ink,
                    )
                }
                is ReplyBlock.Heading -> Text(
                    text = block.text,
                    fontFamily = WiqoSans,
                    fontSize = if (block.level == 1) 20.sp else if (block.level == 2) 18.sp else 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.ink,
                )
                is ReplyBlock.Bullet -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = block.marker,
                        fontFamily = WiqoSans,
                        fontSize = 15.sp,
                        color = colors.ink.copy(alpha = 0.5f),
                    )
                    SelectionContainer(Modifier.weight(1f)) {
                        Text(
                            text = block.text,
                            fontFamily = WiqoSans,
                            fontSize = 15.sp,
                            lineHeight = 22.sp,
                            color = colors.ink,
                        )
                    }
                }
                is ReplyBlock.Quote -> Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(colors.inset, RoundedCornerShape(8.dp))
                        .padding(12.dp),
                ) {
                    Text(
                        text = block.text,
                        fontFamily = WiqoSans,
                        fontSize = 14.sp,
                        color = colors.ink.copy(alpha = 0.8f),
                    )
                }
                is ReplyBlock.Rule -> Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(0.5.dp)
                        .background(colors.line),
                )
                is ReplyBlock.Code -> WiqoCodeBlock(
                    code = block.text,
                    title = block.language.ifBlank { "kod" },
                    isDiff = block.language.equals("diff", ignoreCase = true),
                )
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
